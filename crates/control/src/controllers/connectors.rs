use axum::extract::Extension;
use axum::extract::Path;
use axum::response::IntoResponse;
use axum::Json;
use hyper::StatusCode;
use sqlx::PgPool;

use crate::controllers::Payload;
use crate::models::connectors::CreateConnector;
use crate::models::Id;
use crate::repo::connector_images as images_repo;
use crate::repo::connectors as connectors_repo;

pub async fn index(Extension(db): Extension<PgPool>) -> impl IntoResponse {
    match connectors_repo::fetch_all(&db).await {
        Ok(connectors) => (StatusCode::OK, Json(Payload::Data(connectors))),
        Err(error) => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(Payload::Error(error.to_string())),
        ),
    }
}

pub async fn create(
    Extension(db): Extension<PgPool>,
    Json(input): Json<CreateConnector>,
) -> impl IntoResponse {
    match connectors_repo::insert(&db, input).await {
        Ok(connector) => (StatusCode::CREATED, Json(Payload::Data(connector))),
        Err(error) => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(Payload::Error(error.to_string())),
        ),
    }
}

pub async fn images(
    Extension(db): Extension<PgPool>,
    Path(connector_id): Path<Id>,
) -> impl IntoResponse {
    match images_repo::fetch_all_for_connector(&db, connector_id).await {
        Ok(images) => (StatusCode::OK, Json(Payload::Data(images))),
        Err(error) => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(Payload::Error(error.to_string())),
        ),
    }
}