//! Carries the page's `/connect` WebSockets, which a URI scheme can't
//! answer, to sessions of the app's own, as `mac/`'s `SocketBridge`
//! does.
//!
//! `bridge.js` stands in for `WebSocket` on that one URL and posts what the
//! page does to the `cohesionSocket` script message handler. The bridge
//! opens a session for each socket, relays text frames both ways unchanged,
//! and closes either side when the other closes. The page talks to it as it
//! would to `cohesion open`: `/connect?token=<token>`, refused without the
//! session's token.

use std::{cell::RefCell, collections::HashMap, rc::Rc};

use cohesion_rs::protocol::{Frame, ServerMessage};
use gtk::{gio, glib};
use serde::Deserialize;
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use webkit6::{UserContentManager, WebView, prelude::*};

use crate::{
    RUNTIME,
    connection::{self, Ending},
    pairing::RemotePairing,
};

pub const SCRIPT: &str = include_str!("bridge.js");
const HANDLER: &str = "cohesionSocket";

/// What the page did to one of its sockets.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum PageOp {
    Open {
        id: String,
        token: String,
    },
    Send {
        id: String,
        text: String,
    },
    Close {
        id: String,
    },
    /// A new document: the last one's sockets are gone.
    Reset,
}

/// What to tell the page, or the window.
enum Event {
    Opened(String),
    Message(String, String),
    Closed(String, u16),
    /// A session's `hello` named a build other than the one showing.
    UpdateAvailable,
}

pub struct SocketBridge {
    pairing: RemotePairing,
    token: String,
    /// The build showing, which each session's `hello` is checked against.
    hash: String,
    /// Each open socket's outbox, by the id the page gave the socket.
    sessions: RefCell<HashMap<String, UnboundedSender<String>>>,
    events: UnboundedSender<Event>,
}

impl SocketBridge {
    /// Listens on `content` for the page in `view`; `on_update` runs when a
    /// session finds the server serving a newer build.
    pub fn attach(
        content: &UserContentManager,
        view: &WebView,
        pairing: RemotePairing,
        token: String,
        hash: String,
        on_update: impl Fn() + 'static,
    ) -> Rc<SocketBridge> {
        let (events, mut received) = unbounded_channel();
        let bridge = Rc::new(SocketBridge {
            pairing,
            token,
            hash,
            sessions: RefCell::default(),
            events,
        });
        content.register_script_message_handler(HANDLER, None);
        let weak = Rc::downgrade(&bridge);
        content.connect_script_message_received(Some(HANDLER), move |_, value| {
            let Some(bridge) = weak.upgrade() else { return };
            let op = value
                .to_json(0)
                .and_then(|json| serde_json::from_str::<PageOp>(&json).ok());
            if let Some(op) = op {
                bridge.receive(op);
            }
        });
        // Told to the page in order, on the main thread.
        let view = view.downgrade();
        let weak = Rc::downgrade(&bridge);
        glib::spawn_future_local(async move {
            while let Some(event) = received.recv().await {
                let Some(view) = view.upgrade() else { return };
                let call = match event {
                    Event::Opened(id) => format!("opened({})", json(&id)),
                    Event::Message(id, text) => format!("message({}, {})", json(&id), json(&text)),
                    Event::Closed(id, code) => {
                        if let Some(bridge) = weak.upgrade() {
                            bridge.sessions.borrow_mut().remove(&id);
                        }
                        format!("closed({}, {code})", json(&id))
                    }
                    Event::UpdateAvailable => {
                        on_update();
                        continue;
                    }
                };
                view.evaluate_javascript(
                    &format!("window.__cohesionSocket.{call}"),
                    None,
                    None,
                    None::<&gio::Cancellable>,
                    |_| {},
                );
            }
        });
        bridge
    }

    fn receive(&self, op: PageOp) {
        match op {
            PageOp::Open { id, token } => self.open(id, token),
            PageOp::Send { id, text } => {
                if let Some(outbox) = self.sessions.borrow().get(&id) {
                    let _ = outbox.send(text);
                }
            }
            PageOp::Close { id } => {
                // Dropping the outbox ends the session.
                self.sessions.borrow_mut().remove(&id);
                let _ = self.events.send(Event::Closed(id, 1000));
            }
            PageOp::Reset => self.sessions.borrow_mut().clear(),
        }
    }

    fn open(&self, id: String, token: String) {
        if token != self.token {
            // Policy violation, as the proxy's 401 ends the handshake.
            let _ = self.events.send(Event::Closed(id, 1008));
            return;
        }
        let (outbox, frames) = unbounded_channel();
        self.sessions.borrow_mut().insert(id.clone(), outbox);
        let events = self.events.clone();
        let pairing = self.pairing.clone();
        let hash = self.hash.clone();
        RUNTIME.spawn(async move {
            let Ok(session) = connection::connect(&pairing).await else {
                let _ = events.send(Event::Closed(id, 1006));
                return;
            };
            if events.send(Event::Opened(id.clone())).is_err() {
                return;
            }
            let mut first = true;
            let ending = connection::relay(session, frames, |text| {
                if std::mem::take(&mut first) && names_other_build(&text, &hash) {
                    let _ = events.send(Event::UpdateAvailable);
                }
                events.send(Event::Message(id.clone(), text)).is_ok()
            })
            .await;
            let code = match ending {
                Ending::Closed => 1000,
                Ending::Failed => 1006,
                // The page closed it first, which it was then told.
                Ending::HungUp => return,
            };
            let _ = events.send(Event::Closed(id, code));
        });
    }
}

/// Whether `frame` is a `hello` naming a build of the web UI other than `hash`.
fn names_other_build(frame: &str, hash: &str) -> bool {
    match serde_json::from_str::<Frame>(frame).map(|frame| frame.message) {
        Ok(ServerMessage::Hello(hello)) => hello.web_bundle_hash.is_some_and(|other| other != hash),
        _ => false,
    }
}

/// `value` as a JavaScript string literal.
fn json(value: &str) -> String {
    serde_json::to_string(value).expect("strings always serialize")
}
