use super::errors::Error;
use super::networktunnel::NetworkTunnel;

use async_trait::async_trait;
use futures::pin_mut;
use schemars::JsonSchema;
use std::net::SocketAddr;
use std::sync::Arc;
use thrussh::{
    client,
    client::{Handle, Session},
};
use thrussh_keys::key;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::ReadHalf;
use tokio::net::{TcpListener, TcpStream};
use url::Url;

use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, JsonSchema, PartialEq)]
#[serde(rename_all = "camelCase")]
#[serde(deny_unknown_fields)]
pub struct SshForwardingConfig {
    /// Endpoint of the remote SSH server that supports tunneling, in the form of ssh://hostname[:port]
    pub ssh_endpoint: String,
    /// User name to connect to the remote SSH server.
    pub user: String,
    /// Private key to connect to the remote SSH server.
    pub private_key: String,
    /// Host name to connect from the remote SSH server to the remote destination (e.g. DB) via internal network.
    pub forward_host: String,
    /// Port of the remote destination.
    pub forward_port: u16,
    /// Local port to start the SSH tunnel.
    pub local_port: u16,
}

pub struct SshForwarding {
    config: SshForwardingConfig,
    ssh_client: Option<Handle<ClientHandler>>,
    local_listener: Option<TcpListener>,
}

impl SshForwarding {
    const DEFAULT_SSH_PORT: u16 = 22;

    pub fn new(config: SshForwardingConfig) -> Self {
        Self {
            config,
            ssh_client: None,
            local_listener: None,
        }
    }

    pub async fn prepare_ssh_client(&mut self) -> Result<(), Error> {
        let ssh_addrs =
            Url::parse(&self.config.ssh_endpoint)?.socket_addrs(|| Some(Self::DEFAULT_SSH_PORT))?;
        let ssh_addr = ssh_addrs.get(0).ok_or(Error::InvalidSshEndpoint)?;
        let config = Arc::new(client::Config::default());
        let handler = ClientHandler {};
        self.ssh_client = Some(client::connect(config, ssh_addr, handler).await?);

        Ok(())
    }

    pub async fn prepare_local_listener(&mut self) -> Result<(), Error> {
        if self.config.local_port == 0 {
            return Err(Error::ZeroLocalPort);
        }
        let local_listen_addr: SocketAddr =
            format!("127.0.0.1:{}", self.config.local_port).parse()?;
        self.local_listener = Some(TcpListener::bind(local_listen_addr).await?);

        Ok(())
    }

    pub async fn authenticate(&mut self) -> Result<(), Error> {
        // TODO: this breaks on the new OpenSSH keys, see:
        // https://stackoverflow.com/questions/54994641/openssh-private-key-to-rsa-private-key
        let key_pair = Arc::new(key::KeyPair::RSA {
            key: openssl::rsa::Rsa::private_key_from_pem(&self.config.private_key.as_bytes())?,
            hash: key::SignatureHash::SHA2_256,
        });

        let sc = self
            .ssh_client
            .as_mut()
            .expect("ssh_client is uninitialized.");
        if !sc
            .authenticate_publickey(&self.config.user, key_pair)
            .await?
        {
            return Err(Error::InvalidSshCredential);
        }

        Ok(())
    }
}

#[async_trait]
impl NetworkTunnel for SshForwarding {
    async fn prepare(&mut self) -> Result<(), Error> {
        self.prepare_ssh_client().await?;
        self.prepare_local_listener().await?;
        self.authenticate().await?;
        Ok(())
    }

    async fn start_serve(&mut self) -> Result<(), Error> {
        let sc = self
            .ssh_client
            .as_mut()
            .expect("ssh_client is uninitialized.");
        let ll = self
            .local_listener
            .as_mut()
            .expect("local_listener is uninitialized.");
        loop {
            let (forward_stream, _) = ll.accept().await?;
            let bastion_channel = sc
                .channel_open_direct_tcpip(
                    &self.config.forward_host,
                    self.config.forward_port as u32,
                    "127.0.0.1",
                    0,
                )
                .await?;
            tokio::task::spawn(async move {
                if let Err(err) = tunnel_streaming(forward_stream, bastion_channel).await {
                    tracing::error!(error = ?err, "tunnel_streaming failed.");
                    std::process::exit(1);
                }
            });
        }
    }
}

async fn start_reading_forward_stream(
    mut stream: ReadHalf<'_>,
    mut buf: Vec<u8>,
) -> Result<(usize, ReadHalf<'_>, Vec<u8>), Error> {
    let n = stream.read(&mut buf).await?;
    Ok((n, stream, buf))
}

async fn tunnel_streaming(
    mut forward_stream: TcpStream,
    mut bastion_channel: client::Channel,
) -> Result<(), Error> {
    let (forward_stream_read, mut forward_stream_write) = forward_stream.split();

    // Allocate a buffer of 128 KiB for forward stream.
    let buf_forward_stream = vec![0; 2 << 17];
    let reading = start_reading_forward_stream(forward_stream_read, buf_forward_stream);
    pin_mut!(reading);

    loop {
        tokio::select! {
            r = &mut reading => match r {
                Ok((n, forward_stream_read, buf_forward_stream)) => {
                    match n {
                        0 => {
                            bastion_channel.eof().await?;
                            break
                        },
                        n => {
                          bastion_channel.data(&buf_forward_stream[..n]).await?;
                        }
                    }
                    // The `pin_mut!` called on `reading` turns it into a Pin of a mutable Future.
                    // The `reading.set` replaces the terminated future behind the pinned pointer with a new future to be polled.
                    reading.set(start_reading_forward_stream(forward_stream_read, buf_forward_stream));
                },
                Err(e) => return Err(e),
            },

            // bastion_channel.wait() is calling `recv()` on a receiver, which is safe to cancel.
            // https://doc.servo.org/tokio/sync/mpsc/struct.Receiver.html#cancel-safety
            bastion_channel_data = bastion_channel.wait() => match bastion_channel_data {
                None => {}, // Ignore None values, keep polling.
                Some(chan_msg) => match chan_msg {
                    thrussh::ChannelMsg::Eof => {
                      forward_stream_write.flush().await?;
                      break;
                    },

                    thrussh::ChannelMsg::Data { ref data } => {
                        forward_stream_write.write(data).await?;
                    },
                    // Ignore the other control messages, keep polling.
                    msg => { tracing::info!("SSH control message: {:?}", msg)}
                }
            }
        }
    }
    Ok(())
}

pub struct ClientHandler {}

impl client::Handler for ClientHandler {
    type Error = thrussh::Error;
    type FutureUnit = futures::future::Ready<Result<(Self, client::Session), Self::Error>>;
    type FutureBool = futures::future::Ready<Result<(Self, bool), Self::Error>>;

    // For the tunneling application, trivial functions, which immediately return Ready futures, are sufficient for
    // the default implementations of the other APIs of the client handler.
    fn finished_bool(self, b: bool) -> Self::FutureBool {
        futures::future::ready(Ok((self, b)))
    }
    fn finished(self, session: Session) -> Self::FutureUnit {
        futures::future::ready(Ok((self, session)))
    }

    fn auth_banner(self, banner: &str, session: Session) -> Self::FutureUnit {
        tracing::info!(banner);
        self.finished(session)
    }

    fn check_server_key(self, server_public_key: &key::PublicKey) -> Self::FutureBool {
        tracing::info!("received server public key: {:?}", server_public_key);
        self.finished_bool(true)
    }
}