//! The web UI's build as cohesiond hands it out, held in memory and kept
//! unpacked on disk by hash.

use std::{collections::HashMap, fs, io::Read, path::PathBuf};

use cohesion_rs::protocol::{
    Frame, Outcome, ReplyData, Request, ServerMessage, WebBundle, WebBundleRequest,
};
use futures_util::SinkExt;
use gtk::glib;
use tokio_tungstenite::tungstenite::Message;

use crate::{
    connection::{self, ConnectionError},
    pairing::RemotePairing,
};

/// Why the web UI couldn't be loaded.
pub enum LoadError {
    Connection(ConnectionError),
    /// The daemon was built without `web/build/`.
    NoWebUI,
    Malformed,
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connection(err) => err.fmt(f),
            Self::NoWebUI => f.write_str("This server wasn’t built with the web UI."),
            Self::Malformed => f.write_str("Couldn’t unpack the web UI."),
        }
    }
}

impl From<ConnectionError> for LoadError {
    fn from(err: ConnectionError) -> Self {
        Self::Connection(err)
    }
}

/// Every file of one build of the web UI. Only the newest build is kept on
/// disk: `<hash>/manifest.json` lists the files under `<hash>/files/`, and a
/// build counts as cached once its manifest, written last, is there.
pub struct WebAssets {
    pub hash: String,
    files: HashMap<String, glib::Bytes>,
}

/// The id of the one request a loading session sends.
const BUNDLE_REQUEST: u64 = 1;

impl WebAssets {
    /// The build the server serves: the cached copy when the hash in its
    /// `hello` matches one, else fetched with `webBundle` over the same session.
    pub async fn load(pairing: RemotePairing) -> Result<WebAssets, LoadError> {
        let mut session = connection::connect(&pairing).await?;
        let hello = connection::next_text(&mut session).await?;
        let hash = match serde_json::from_str::<Frame>(&hello).map(|frame| frame.message) {
            Ok(ServerMessage::Hello(hello)) => hello.web_bundle_hash.ok_or(LoadError::NoWebUI)?,
            _ => return Err(LoadError::Malformed),
        };
        if let Some(cached) = Self::cached(&hash) {
            let _ = session.close(None).await;
            return Ok(cached);
        }

        let request = Request {
            id: Some(BUNDLE_REQUEST),
            command: WebBundleRequest.into(),
        };
        let request = serde_json::to_string(&request).expect("requests always serialize");
        session
            .send(Message::text(request))
            .await
            .map_err(|err| ConnectionError::Disconnected(err.to_string()))?;
        loop {
            let text = connection::next_text(&mut session).await?;
            let Ok(Frame {
                message: ServerMessage::Reply(reply),
                ..
            }) = serde_json::from_str::<Frame>(&text)
            else {
                continue;
            };
            if reply.id != Some(BUNDLE_REQUEST) {
                continue;
            }
            let _ = session.close(None).await;
            return match reply.outcome {
                Outcome::Ok(ReplyData::WebBundle(bundle)) => Self::unpack(bundle),
                Outcome::Ok(_) => Err(LoadError::Malformed),
                Outcome::Error(err) => Err(ConnectionError::Refused(err.message).into()),
            };
        }
    }

    /// The file at `path`, or `index.html` for any path the build doesn't
    /// have, so the UI's client-side routes load on refresh.
    pub fn file<'a>(&'a self, path: &'a str) -> Option<(&'a str, &'a glib::Bytes)> {
        if let Some(data) = self.files.get(path) {
            return Some((path, data));
        }
        self.files
            .get("index.html")
            .map(|data| ("index.html", data))
    }

    fn cache_dir() -> PathBuf {
        crate::cache_dir().join("WebUI")
    }

    /// The build with `hash`, if this app unpacked it before.
    fn cached(hash: &str) -> Option<WebAssets> {
        let directory = Self::cache_dir().join(hash);
        let manifest = fs::read(directory.join("manifest.json")).ok()?;
        let paths: Vec<String> = serde_json::from_slice(&manifest).ok()?;
        let mut files = HashMap::new();
        for path in paths {
            let data = fs::read(directory.join("files").join(&path)).ok()?;
            files.insert(path, glib::Bytes::from_owned(data));
        }
        Some(WebAssets {
            hash: hash.to_string(),
            files,
        })
    }

    /// Inflates every file in `bundle` and caches the build in place of any other.
    fn unpack(bundle: WebBundle) -> Result<WebAssets, LoadError> {
        let mut files = HashMap::new();
        for file in &bundle.files {
            let deflated = file.deflated().map_err(|_| LoadError::Malformed)?;
            let mut data = Vec::new();
            flate2::read::DeflateDecoder::new(deflated.as_slice())
                .read_to_end(&mut data)
                .map_err(|_| LoadError::Malformed)?;
            files.insert(file.path.clone(), glib::Bytes::from_owned(data));
        }
        let assets = WebAssets {
            hash: bundle.hash,
            files,
        };
        // A build that can't be cached still serves.
        if let Err(err) = assets.save() {
            eprintln!("couldn't cache the web UI: {err}");
        }
        Ok(assets)
    }

    fn save(&self) -> std::io::Result<()> {
        let root = Self::cache_dir();
        let directory = root.join(&self.hash);
        let _ = fs::remove_dir_all(&root);
        for (path, data) in &self.files {
            let file = directory.join("files").join(path);
            fs::create_dir_all(file.parent().expect("a file is inside its build"))?;
            fs::write(file, data)?;
        }
        let paths: Vec<&String> = self.files.keys().collect();
        fs::write(
            directory.join("manifest.json"),
            serde_json::to_vec(&paths).expect("paths always serialize"),
        )
    }
}
