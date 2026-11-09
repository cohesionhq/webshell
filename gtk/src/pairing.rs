//! This app's registration with a cohesiond elsewhere, made from a setup
//! code, and where it is kept.

mod tls;

use std::{fs, io::ErrorKind, path::PathBuf};

use cohesion_rs::{
    Authentication, Host, SetupCode,
    private_files::{create_private_dir, write_private},
    protocol::{Frame, Outcome, RegisterRequest, ServerMessage},
};
use rustls::{
    ClientConfig,
    pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
};
use serde::{Deserialize, Serialize};

/// Where the server is, the key its certificate must carry, and the
/// certificate and key this app presents to it.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct RemotePairing {
    pub host: Host,
    /// The HTTPS port, as the setup code gave it.
    pub port: u16,
    /// SHA-256 of the server's public key, which its certificate must match.
    server_fingerprint: String,
    /// This app's self-signed certificate followed by its private key.
    identity_pem: String,
}

/// Why pairing didn't happen.
pub enum PairingError {
    InvalidSetupCode,
    CannotCreateIdentity,
    /// cohesiond refused the registration, saying why.
    Refused(String),
    Unreachable(String),
}

impl std::fmt::Display for PairingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSetupCode => f.write_str("That isn’t a valid setup code."),
            Self::CannotCreateIdentity => f.write_str("Couldn’t create a certificate."),
            Self::Refused(reason) => f.write_str(reason),
            Self::Unreachable(reason) => write!(f, "Couldn’t reach Cohesion: {reason}"),
        }
    }
}

impl RemotePairing {
    /// Registers a new key and certificate, named `name`, with the server
    /// that printed `setup_code`.
    pub async fn register(setup_code: &str, name: &str) -> Result<RemotePairing, PairingError> {
        let code = SetupCode::decode(setup_code).map_err(|_| PairingError::InvalidSetupCode)?;
        let identity_pem = Authentication::generate()
            .ok()
            .and_then(|key| key.self_signed_certificate_pem(name).ok())
            .ok_or(PairingError::CannotCreateIdentity)?;
        let pairing = RemotePairing {
            host: code.host,
            port: code.port,
            server_fingerprint: code.fingerprint,
            identity_pem,
        };
        let request = RegisterRequest {
            setup_key: code.key,
            client_name: name.to_string(),
        };
        pairing.post_register(&request).await?;
        Ok(pairing)
    }

    /// `host:port`, with an IPv6 address in brackets.
    pub fn address(&self) -> String {
        self.host.with_port(self.port)
    }

    /// `https://host:port`, as `/client` tells the web UI where the daemon is.
    pub fn base_url(&self) -> String {
        format!("https://{}", self.address())
    }

    /// TLS presenting this pairing's certificate and trusting only its
    /// server, offering `alpn`. `None` when the saved identity can't be read.
    pub fn tls(&self, alpn: &[&[u8]]) -> Option<ClientConfig> {
        let pem = self.identity_pem.as_bytes();
        let chain = CertificateDer::pem_slice_iter(pem)
            .collect::<Result<Vec<_>, _>>()
            .ok()?;
        let key = PrivateKeyDer::from_pem_slice(pem).ok()?;
        let mut config = tls::client_config(chain, key, self.server_fingerprint.clone()).ok()?;
        config.alpn_protocols = alpn.iter().map(|p| p.to_vec()).collect();
        Some(config)
    }

    /// Asks cohesiond to trust this pairing's certificate. cohesiond judges
    /// a connection by its certificate when it opens, so the client that
    /// registered stays unregistered and is thrown away.
    async fn post_register(&self, request: &RegisterRequest) -> Result<(), PairingError> {
        let tls = self
            .tls(&[b"http/1.1"])
            .ok_or(PairingError::CannotCreateIdentity)?;
        let http = reqwest::Client::builder()
            .tls_backend_preconfigured(tls)
            .build()
            .map_err(|err| PairingError::Unreachable(err.to_string()))?;
        let response = http
            .post(format!("{}/register", self.base_url()))
            .json(request)
            .send()
            .await
            .map_err(|err| PairingError::Unreachable(err.to_string()))?;
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| PairingError::Unreachable(err.to_string()))?;
        match serde_json::from_str::<Frame>(&body).map(|frame| frame.message) {
            Ok(ServerMessage::Reply(reply)) => match reply.outcome {
                Outcome::Ok(_) => Ok(()),
                Outcome::Error(error) => Err(PairingError::Refused(error.message)),
            },
            _ if status == reqwest::StatusCode::UNAUTHORIZED => Err(PairingError::Refused(
                "That setup code wasn’t accepted. Make a new one on the server.".to_string(),
            )),
            _ if body.is_empty() => Err(PairingError::Refused(format!("HTTP {status}"))),
            _ => Err(PairingError::Refused(body)),
        }
    }
}

/// Where the pairing is kept: a file only this user may read, in this app's
/// configuration directory.
pub struct PairingStore;

impl PairingStore {
    fn file() -> PathBuf {
        crate::config_dir().join("pairing.json")
    }

    /// The server this app paired with, if it has. A pairing that can't be
    /// read is as good as none.
    pub fn load() -> Option<RemotePairing> {
        let text = match fs::read_to_string(Self::file()) {
            Ok(text) => text,
            Err(err) if err.kind() == ErrorKind::NotFound => return None,
            Err(err) => {
                eprintln!("couldn't read the pairing: {err}");
                return None;
            }
        };
        serde_json::from_str(&text).ok()
    }

    pub fn save(pairing: &RemotePairing) -> std::io::Result<()> {
        create_private_dir(&crate::config_dir())?;
        let json = serde_json::to_vec(pairing).expect("a pairing always serializes");
        write_private(&Self::file(), &json)
    }

    /// Forgets the pairing, and with it the key the server trusts.
    pub fn remove() {
        if let Err(err) = fs::remove_file(Self::file())
            && err.kind() != ErrorKind::NotFound
        {
            eprintln!("couldn't remove the pairing: {err}");
        }
    }
}

/// The name pairing suggests: this computer's hostname.
pub fn device_name() -> String {
    gtk::glib::host_name().to_string()
}
