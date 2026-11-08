//! Sessions with cohesiond: a WebSocket to `/connect` on the paired server,
//! over mutual TLS.

use std::{sync::Arc, time::Duration};

use futures_util::{SinkExt, StreamExt};
use tokio::{net::TcpStream, sync::mpsc::UnboundedReceiver};
use tokio_tungstenite::{
    Connector, MaybeTlsStream, WebSocketStream,
    tungstenite::{self, Message, protocol::WebSocketConfig},
};

use crate::pairing::RemotePairing;

pub type Session = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// The longest frame cohesiond sends: `FRAME_LIMIT` in
/// `unix_socket_exchange.rs`, and axum's default on the WebSocket. The web
/// bundle is one frame, so tungstenite's 16 MiB default would drop it.
const MAXIMUM_MESSAGE_SIZE: usize = 64 * 1024 * 1024;

/// How often a session is pinged; one unanswered by the next ping has died
/// quietly, and ends.
const HEARTBEAT: Duration = Duration::from_secs(15);

/// Why a session with cohesiond couldn't open or broke.
pub enum ConnectionError {
    /// The server doesn't trust this app's pairing, or it can't be read.
    Unpaired,
    Unreachable(String),
    Disconnected(String),
    /// cohesiond refused the session, saying why.
    Refused(String),
}

impl std::fmt::Display for ConnectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unpaired => f.write_str("The server doesn’t trust this device any more."),
            Self::Unreachable(reason) => write!(f, "Couldn’t reach Cohesion: {reason}"),
            Self::Disconnected(reason) => write!(f, "Lost the connection to Cohesion: {reason}"),
            Self::Refused(reason) => f.write_str(reason),
        }
    }
}

/// Opens a new session with the server `pairing` names.
pub async fn connect(pairing: &RemotePairing) -> Result<Session, ConnectionError> {
    // WebSocket upgrades need HTTP/1.1.
    let tls = pairing
        .tls(&[b"http/1.1"])
        .ok_or(ConnectionError::Unpaired)?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAXIMUM_MESSAGE_SIZE))
        .max_frame_size(Some(MAXIMUM_MESSAGE_SIZE));
    let (session, _) = tokio_tungstenite::connect_async_tls_with_config(
        format!("wss://{}/connect", pairing.address()),
        Some(config),
        false,
        Some(Connector::Rustls(Arc::new(tls))),
    )
    .await
    .map_err(|err| match err {
        // cohesiond refuses `/connect` to a certificate it doesn't trust,
        // as after the client was removed.
        tungstenite::Error::Http(response) if response.status() == 403 => ConnectionError::Unpaired,
        err => ConnectionError::Unreachable(err.to_string()),
    })?;
    Ok(session)
}

/// The next text frame of `session`, skipping the rest.
pub async fn next_text(session: &mut Session) -> Result<String, ConnectionError> {
    while let Some(message) = session.next().await {
        match message {
            Ok(Message::Text(text)) => return Ok(text.to_string()),
            Ok(_) => {}
            Err(err) => return Err(ConnectionError::Disconnected(err.to_string())),
        }
    }
    Err(ConnectionError::Disconnected(
        "Cohesion closed the session.".to_string(),
    ))
}

/// How a relayed session ended.
pub enum Ending {
    /// cohesiond closed it.
    Closed,
    /// It broke, or stopped answering pings.
    Failed,
    /// The other side hung up first, so nobody is told.
    HungUp,
}

/// Passes text frames both ways unchanged, as `cohesion open`'s `bridge.rs`
/// does: from `outbox` to cohesiond, and from cohesiond to `deliver`, until
/// either side closes or `deliver` returns `false`.
pub async fn relay(
    mut session: Session,
    mut outbox: UnboundedReceiver<String>,
    mut deliver: impl FnMut(String) -> bool,
) -> Ending {
    let mut heartbeat =
        tokio::time::interval_at(tokio::time::Instant::now() + HEARTBEAT, HEARTBEAT);
    let mut answered = true;
    loop {
        tokio::select! {
            message = session.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    if !deliver(text.to_string()) {
                        break;
                    }
                }
                Some(Ok(Message::Pong(_))) => answered = true,
                Some(Ok(Message::Close(_))) | None => return Ending::Closed,
                Some(Ok(_)) => {}
                Some(Err(_)) => return Ending::Failed,
            },
            frame = outbox.recv() => match frame {
                Some(frame) => {
                    if session.send(Message::text(frame)).await.is_err() {
                        return Ending::Failed;
                    }
                }
                None => break,
            },
            _ = heartbeat.tick() => {
                if !answered || session.send(Message::Ping(Default::default())).await.is_err() {
                    return Ending::Failed;
                }
                answered = false;
            }
        }
    }
    let _ = session.close(None).await;
    Ending::HungUp
}
