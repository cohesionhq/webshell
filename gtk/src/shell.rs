//! What the app's windows share: the accounts, each account's pages'
//! storage, and the app's actions.

use std::{cell::RefCell, collections::HashMap, rc::Rc};

use adw::prelude::*;
use gtk::{gio, glib};
use webkit6::NetworkSession;

use crate::{
    pairing::{PairingStore, RemotePairing},
    window::CohesionWindow,
};

pub struct Shell {
    pub app: adw::Application,
    /// The servers this app paired with, each an account, in the order they
    /// were made.
    pairings: RefCell<Vec<RemotePairing>>,
    /// Each account's pages share one, and so their storage, by its id.
    networks: RefCell<HashMap<String, NetworkSession>>,
    windows: RefCell<Vec<Rc<CohesionWindow>>>,
    /// The account switcher's menu: the accounts, then "Add account…".
    pub accounts_menu: gio::Menu,
}

impl Shell {
    /// Sets up the app's actions, and opens a window each time it is activated.
    pub fn start(app: &adw::Application) {
        let shell = Rc::new(Shell {
            app: app.clone(),
            pairings: RefCell::new(PairingStore::load()),
            networks: RefCell::default(),
            windows: RefCell::default(),
            accounts_menu: gio::Menu::new(),
        });
        shell.update_accounts_menu();

        // On the frontmost window's account, or the first.
        let new_window = gio::SimpleAction::new("new-window", None);
        let weak = Rc::downgrade(&shell);
        new_window.connect_activate(move |_, _| {
            let Some(shell) = weak.upgrade() else { return };
            let account = shell
                .active_window()
                .and_then(|window| window.account())
                .or_else(|| shell.first_account());
            shell.open_window(account);
        });
        let quit = gio::SimpleAction::new("quit", None);
        let app_ref = app.downgrade();
        quit.connect_activate(move |_, _| {
            if let Some(app) = app_ref.upgrade() {
                app.quit();
            }
        });
        app.add_action(&new_window);
        app.add_action(&quit);
        app.set_accels_for_action("app.new-window", &["<Control><Alt>n"]);
        app.set_accels_for_action("win.preferences", &["<Control>comma"]);
        app.set_accels_for_action("app.quit", &["<Control>q"]);
        app.set_accels_for_action("window.close", &["<Control>w"]);

        // Held by the handler, the shell lives as long as the app.
        app.connect_activate(move |_| shell.open_window(shell.first_account()));
    }

    /// The account with this id, if the app is still paired with it.
    pub fn pairing(&self, id: &str) -> Option<RemotePairing> {
        self.pairings
            .borrow()
            .iter()
            .find(|pairing| pairing.id() == id)
            .cloned()
    }

    fn first_account(&self) -> Option<String> {
        self.pairings
            .borrow()
            .first()
            .map(|pairing| pairing.id().to_string())
    }

    /// The network session `pairing`'s pages share, and so their storage,
    /// apart from every other account's.
    pub fn network(&self, pairing: &RemotePairing) -> NetworkSession {
        self.networks
            .borrow_mut()
            .entry(pairing.id().to_string())
            .or_insert_with(|| {
                let name = pairing.storage_name();
                let data = crate::data_dir().join("accounts").join(&name);
                let cache = crate::cache_dir().join("accounts").join(&name);
                NetworkSession::new(data.to_str(), cache.to_str())
            })
            .clone()
    }

    /// Keeps `pairing`, in place of an earlier one with the same server, and
    /// loads every window on it again.
    pub fn add_pairing(&self, pairing: RemotePairing) {
        let id = pairing.id().to_string();
        {
            let mut pairings = self.pairings.borrow_mut();
            match pairings.iter_mut().find(|kept| kept.id() == id) {
                Some(kept) => *kept = pairing,
                None => pairings.push(pairing),
            }
        }
        self.saved(&id);
    }

    /// Forgets the account with this id, and the key its server trusts.
    /// Windows on it show the pairing page.
    pub fn remove_pairing(&self, id: &str) {
        self.pairings
            .borrow_mut()
            .retain(|pairing| pairing.id() != id);
        self.saved(id);
    }

    /// Whether the app has paired with any server.
    pub fn has_pairings(&self) -> bool {
        !self.pairings.borrow().is_empty()
    }

    /// Saves the pairings after a change to the account `id`, shows them in
    /// the account switcher, and loads the windows on it again.
    fn saved(&self, id: &str) {
        if let Err(err) = PairingStore::save(&self.pairings.borrow()) {
            eprintln!("couldn't save the pairings: {err}");
        }
        self.update_accounts_menu();
        let windows = self.windows.borrow().clone();
        for window in windows {
            if window.account().as_deref() == Some(id) {
                window.load();
            } else {
                window.show_account();
            }
        }
    }

    /// Each account, as a choice of the window's `win.account`, then
    /// "Add account…".
    fn update_accounts_menu(&self) {
        let menu = &self.accounts_menu;
        menu.remove_all();
        let accounts = gio::Menu::new();
        for pairing in self.pairings.borrow().iter() {
            let item = gio::MenuItem::new(Some(&pairing.label()), None);
            item.set_action_and_target_value(Some("win.account"), Some(&pairing.id().to_variant()));
            accounts.append_item(&item);
        }
        menu.append_section(None, &accounts);
        let add = gio::Menu::new();
        add.append(Some("Add account…"), Some("win.add-account"));
        menu.append_section(None, &add);
    }

    fn active_window(&self) -> Option<Rc<CohesionWindow>> {
        let active = self.app.active_window()?;
        self.windows
            .borrow()
            .iter()
            .find(|window| window.window.upcast_ref::<gtk::Window>() == &active)
            .cloned()
    }

    /// Opens a window on the account with this id, or on the pairing page.
    fn open_window(self: &Rc<Self>, account: Option<String>) {
        let window = CohesionWindow::new(self, account);
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
