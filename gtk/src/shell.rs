//! What the app's windows share: the pairing, the pages' storage, and the
//! app's actions.

use std::{cell::RefCell, rc::Rc};

use adw::prelude::*;
use gtk::{gio, glib};
use webkit6::NetworkSession;

use crate::{
    pairing::{PairingStore, RemotePairing},
    preferences,
    window::CohesionWindow,
};

pub struct Shell {
    pub app: adw::Application,
    pairing: RefCell<Option<RemotePairing>>,
    /// Every window's pages share it, and so their storage.
    pub network: NetworkSession,
    windows: RefCell<Vec<Rc<CohesionWindow>>>,
    preferences: gio::SimpleAction,
}

impl Shell {
    /// Sets up the app's actions, and opens a window each time it is activated.
    pub fn start(app: &adw::Application) {
        let data = crate::data_dir().join("web");
        let cache = crate::cache_dir().join("web");
        let shell = Rc::new(Shell {
            app: app.clone(),
            pairing: RefCell::new(PairingStore::load()),
            network: NetworkSession::new(data.to_str(), cache.to_str()),
            windows: RefCell::default(),
            preferences: gio::SimpleAction::new("preferences", None),
        });

        let new_window = gio::SimpleAction::new("new-window", None);
        let weak = Rc::downgrade(&shell);
        new_window.connect_activate(move |_, _| {
            if let Some(shell) = weak.upgrade() {
                shell.open_window();
            }
        });
        let weak = Rc::downgrade(&shell);
        shell.preferences.connect_activate(move |_, _| {
            let Some(shell) = weak.upgrade() else { return };
            if let Some(window) = shell.app.active_window() {
                preferences::present(&shell, &window);
            }
        });
        shell.preferences.set_enabled(shell.pairing().is_some());
        let quit = gio::SimpleAction::new("quit", None);
        let app_ref = app.downgrade();
        quit.connect_activate(move |_, _| {
            if let Some(app) = app_ref.upgrade() {
                app.quit();
            }
        });
        app.add_action(&new_window);
        app.add_action(&shell.preferences);
        app.add_action(&quit);
        app.set_accels_for_action("app.new-window", &["<Control>n"]);
        app.set_accels_for_action("app.preferences", &["<Control>comma"]);
        app.set_accels_for_action("app.quit", &["<Control>q"]);
        app.set_accels_for_action("window.close", &["<Control>w"]);

        // Held by the handler, the shell lives as long as the app.
        app.connect_activate(move |_| shell.open_window());
    }

    /// The server this app paired with, if it has.
    pub fn pairing(&self) -> Option<RemotePairing> {
        self.pairing.borrow().clone()
    }

    /// Keeps `pairing`, or forgets the one kept with `None`, and loads every
    /// window again for it.
    pub fn set_pairing(&self, pairing: Option<RemotePairing>) {
        match &pairing {
            Some(pairing) => {
                if let Err(err) = PairingStore::save(pairing) {
                    eprintln!("couldn't save the pairing: {err}");
                }
            }
            None => PairingStore::remove(),
        }
        self.preferences.set_enabled(pairing.is_some());
        *self.pairing.borrow_mut() = pairing;
        let windows = self.windows.borrow().clone();
        for window in windows {
            window.load();
        }
    }

    fn open_window(self: &Rc<Self>) {
        let window = CohesionWindow::new(self);
        let weak = Rc::downgrade(self);
        let closing = Rc::downgrade(&window);
        window.window.connect_close_request(move |_| {
            if let (Some(shell), Some(closing)) = (weak.upgrade(), closing.upgrade()) {
                shell
                    .windows
                    .borrow_mut()
                    .retain(|w| !Rc::ptr_eq(w, &closing));
            }
            glib::Propagation::Proceed
        });
        self.windows.borrow_mut().push(window.clone());
        window.window.present();
        window.load();
    }
}
