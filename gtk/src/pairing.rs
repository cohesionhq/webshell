//! This app's registrations with cohesiond servers elsewhere, made from
//! setup codes, and where they are kept. Each is an account the app can
//! open a window on.

mod tls;

use std::{fs, io::ErrorKind, path::PathBuf};

use cohesion_rs::{
    Authentication, Host, SetupCode, generated_client_name,
    private_files::{create_private_dir, write_private},
    protocol::{Frame, Outcome, RegisterRequest, ServerMessage},
};
use rustls::{
    ClientConfig,
    pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
};
use serde::{Deserialize, Serialize};

/// Where the server is, the key its certificate must carry, the certificate
/// and key this app presents to it, and what the account is called.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct RemotePairing {
    /// What the person called the account when they paired, if anything.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    account_name: Option<String>,
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
    /// that printed `setup_code`, as the account `account_name` (blank for
    /// none).
    pub async fn register(
        setup_code: &str,
        name: &str,
        account_name: &str,
    ) -> Result<RemotePairing, PairingError> {
        let code = SetupCode::decode(setup_code).map_err(|_| PairingError::InvalidSetupCode)?;
        let identity_pem = Authentication::generate()
            .ok()
            .and_then(|key| key.self_signed_certificate_pem(name).ok())
            .ok_or(PairingError::CannotCreateIdentity)?;
        let account_name = Some(account_name.trim().to_string()).filter(|name| !name.is_empty());
        let pairing = RemotePairing {
            account_name,
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

    /// Which server this is: pairing with the same server again replaces it.
    pub fn id(&self) -> &str {
        &self.server_fingerprint
    }

    /// What the account is called: the name given when pairing, or the
    /// server's name or address, without the port.
    pub fn label(&self) -> String {
        self.account_name
            .clone()
            .unwrap_or_else(|| self.host.to_string())
    }

    /// The directory, under this app's data and cache directories, that
    /// holds this account's pages' storage, so no account's pages see
    /// another's. The fingerprint is hex; anything else in it is dropped.
    pub fn storage_name(&self) -> String {
        self.id().chars().filter(char::is_ascii_hexdigit).collect()
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

/// Where the pairings are kept: a file only this user may read, in this
/// app's configuration directory, listing them in the order they were made.
pub struct PairingStore;

impl PairingStore {
    fn file() -> PathBuf {
        crate::config_dir().join("pairings.json")
    }

    /// Where a single pairing was kept before the app took several.
    fn legacy_file() -> PathBuf {
        crate::config_dir().join("pairing.json")
    }

    /// The servers this app paired with. A file that can't be read is as
    /// good as none. A single pairing kept by an earlier version becomes the
    /// first in the list.
    pub fn load() -> Vec<RemotePairing> {
        if let Some(text) = Self::read(&Self::file()) {
            return serde_json::from_str(&text).unwrap_or_default();
        }
        let Some(pairing) = Self::read(&Self::legacy_file())
            .and_then(|text| serde_json::from_str::<RemotePairing>(&text).ok())
        else {
            return Vec::new();
        };
        let pairings = vec![pairing];
        match Self::save(&pairings) {
            Ok(()) => {
                if let Err(err) = fs::remove_file(Self::legacy_file()) {
                    eprintln!("couldn't remove the old pairing: {err}");
                }
            }
            Err(err) => eprintln!("couldn't save the pairings: {err}"),
        }
        pairings
    }

    fn read(file: &PathBuf) -> Option<String> {
        match fs::read_to_string(file) {
            Ok(text) => Some(text),
            Err(err) if err.kind() == ErrorKind::NotFound => None,
            Err(err) => {
                eprintln!("couldn't read the pairings: {err}");
                None
            }
        }
    }

    /// Keeps `pairings` in place of those kept before; a pairing left out is
    /// forgotten, and with it the key its server trusts.
    pub fn save(pairings: &[RemotePairing]) -> std::io::Result<()> {
        create_private_dir(&crate::config_dir())?;
        let json = serde_json::to_vec(pairings).expect("pairings always serialize");
        write_private(&Self::file(), &json)
    }
}

/// What this app calls itself in a generated client name.
const CLIENT_NAME: &str = "Cohesion";

/// The name pairing suggests, such as `apollo (Cohesion)`: this computer's
/// hostname, then this app. Whatever is typed over it is registered as typed.
pub fn suggested_name() -> String {
    generated_client_name(&gtk::glib::host_name(), CLIENT_NAME)
}
