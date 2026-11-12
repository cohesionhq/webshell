//! One window's web UI, on one account, or what stands in its way: the
//! pairing page when it has no account or the server no longer trusts this
//! app, a spinner while it loads, and why it couldn't.

use std::{cell::RefCell, rc::Rc, sync::Arc};

use adw::prelude::*;
use gtk::{gio, glib};
use webkit6::{LoadEvent, prelude::*};

use crate::{
    RUNTIME,
    assets::{LoadError, WebAssets},
    connection::ConnectionError,
    pairing::RemotePairing,
    pairing_page, preferences,
    session::WebUISession,
    shell::Shell,
};

/// How many times, a second apart, to try reaching a server that may only
/// just have started, or before the network is up.
const ATTEMPTS: u32 = 30;

/// Where the web UI stands.
enum State {
    Loading,
    /// There is no pairing, or the server no longer trusts it.
    Unpaired,
    Ready(WebUISession),
    Failed(String),
}

/// The mouse's back and forward buttons (GDK's 8 and 9) reach the page as a
/// left button. The window sees every button event before WebKit's own
/// controllers do (a capture-phase legacy controller, which reads the raw
/// event), so it keeps these two from WebKit, and hands the page the press and
/// release a browser sends for them (`button` 3 and 4), on which the web UI
/// steps its own history. It acts on the press, so a lost release can't
/// swallow it. It needs no change to the page or the bridge.
fn history_buttons(web: &adw::Bin) -> gtk::EventControllerLegacy {
    let controller = gtk::EventControllerLegacy::new();
    controller.set_propagation_phase(gtk::PropagationPhase::Capture);
    let web = web.downgrade();
    controller.connect_event(move |_, event| {
        let Some(event) = event.downcast_ref::<gtk::gdk::ButtonEvent>() else {
            return glib::Propagation::Proceed;
        };
        let button = match event.button() {
            8 => 3,
            9 => 4,
            _ => return glib::Propagation::Proceed,
        };
        if event.event_type() == gtk::gdk::EventType::ButtonPress
            && let Some(view) = web
                .upgrade()
                .and_then(|web| web.child())
                .and_then(|child| child.downcast::<webkit6::WebView>().ok())
        {
            view.evaluate_javascript(
                &format!(
                    "for (const type of ['mousedown', 'mouseup']) window.dispatchEvent(new MouseEvent(type, {{ button: {button}, bubbles: true, cancelable: true }}))"
                ),
                None,
                None,
                None::<&gio::Cancellable>,
                |_| {},
            );
        }
        glib::Propagation::Stop
    });
    controller
}

pub struct CohesionWindow {
    pub window: adw::ApplicationWindow,
    shell: std::rc::Weak<Shell>,
    header: adw::HeaderBar,
    account_button: gtk::MenuButton,
    /// `win.account`, whose state is the id of the account the window is
    /// on, or empty while it pairs.
    account_action: gio::SimpleAction,
    stack: gtk::Stack,
    web: adw::Bin,
    failed: adw::StatusPage,
    toasts: adw::ToastOverlay,
    update: gio::SimpleAction,
    preferences: gio::SimpleAction,
    /// The id of the account the window is on; `None` until it pairs.
    account: RefCell<Option<String>>,
    state: RefCell<State>,
    loading: RefCell<Option<glib::JoinHandle<()>>>,
}

impl CohesionWindow {
    /// A window on the account with this id, or on the pairing page.
    pub fn new(shell: &Rc<Shell>, account: Option<String>) -> Rc<CohesionWindow> {
        let menu = gio::Menu::new();
        let section = gio::Menu::new();
        section.append(Some("New window"), Some("app.new-window"));
        menu.append_section(None, &section);
        let section = gio::Menu::new();
        section.append(Some("Install update…"), Some("win.update"));
        section.append(Some("Preferences"), Some("win.preferences"));
        menu.append_section(None, &section);
        let menu_button = gtk::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .menu_model(&menu)
            .primary(true)
            .tooltip_text("Main menu")
            .build();
        let header = adw::HeaderBar::builder().show_title(false).build();
        header.add_css_class("overlay");
        header.pack_end(&menu_button);
        // The account switcher, as multi-account GNOME apps have it: the
        // window's account, the others, and "Add account…".
        let account_button = gtk::MenuButton::builder()
            .menu_model(&shell.accounts_menu)
            .tooltip_text("Switch account")
            .build();
        header.pack_end(&account_button);

        let loading = adw::StatusPage::builder().title("Connecting…").build();
        loading.set_paintable(Some(&adw::SpinnerPaintable::new(Some(&loading))));
        let failed = adw::StatusPage::builder()
            .icon_name("dialog-warning-symbolic")
            .title("Can’t connect")
            .build();
        let retry = gtk::Button::builder()
            .label("Try again")
            .halign(gtk::Align::Center)
            .css_classes(["pill"])
            .build();
        failed.set_child(Some(&retry));
        let web = adw::Bin::new();
        let stack = gtk::Stack::new();
        stack.add_named(&loading, Some("loading"));
        stack.add_named(&failed, Some("failed"));
        stack.add_named(&web, Some("web"));

        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&stack));
        let toolbar = adw::ToolbarView::builder()
            .content(&toasts)
            .extend_content_to_top_edge(true)
            .build();
        toolbar.add_top_bar(&header);

        let window = adw::ApplicationWindow::builder()
            .application(&shell.app)
            .title("Cohesion")
            .default_width(1200)
            .default_height(800)
            .width_request(360)
            .height_request(480)
            .content(&toolbar)
            .build();
        let update = gio::SimpleAction::new("update", None);
        update.set_enabled(false);
        window.add_action(&update);
        let preferences = gio::SimpleAction::new("preferences", None);
        preferences.set_enabled(false);
        window.add_action(&preferences);
        let account_action = gio::SimpleAction::new_stateful(
            "account",
            Some(&String::static_variant_type()),
            &account.clone().unwrap_or_default().to_variant(),
        );
        window.add_action(&account_action);
        let add_account = gio::SimpleAction::new("add-account", None);
        window.add_action(&add_account);

        window.add_controller(history_buttons(&web));

        let shell_weak = Rc::downgrade(shell);
        let this = Rc::new(CohesionWindow {
            window,
            shell: Rc::downgrade(shell),
            header,
            account_button,
            account_action,
            stack,
            web,
            failed,
            toasts,
            update,
            preferences,
            account: RefCell::new(account),
            state: RefCell::new(State::Loading),
            loading: RefCell::default(),
        });
        let weak = Rc::downgrade(&this);
        let on_pair = move |pairing: RemotePairing| {
            let (Some(this), Some(shell)) = (weak.upgrade(), shell_weak.upgrade()) else {
                return;
            };
            *this.account.borrow_mut() = Some(pairing.id().to_string());
            shell.add_pairing(pairing);
            this.load();
        };
        this.stack
            .add_named(&pairing_page::new(on_pair), Some("pairing"));
        let weak = Rc::downgrade(&this);
        this.preferences.connect_activate(move |_, _| {
            let Some(this) = weak.upgrade() else { return };
            let (Some(shell), Some(pairing)) = (this.shell.upgrade(), this.pairing()) else {
                return;
            };
            preferences::present(&shell, &pairing, &this.window);
        });
        let weak = Rc::downgrade(&this);
        this.account_action.connect_activate(move |_, target| {
            if let (Some(this), Some(id)) = (weak.upgrade(), target.and_then(|t| t.get::<String>()))
            {
                this.switch_account(Some(id));
            }
        });
        let weak = Rc::downgrade(&this);
        add_account.connect_activate(move |_, _| {
            if let Some(this) = weak.upgrade() {
                this.switch_account(None);
            }
        });
        let weak = Rc::downgrade(&this);
        retry.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.load();
            }
        });
        let weak = Rc::downgrade(&this);
        this.update.connect_activate(move |_, _| {
            if let Some(this) = weak.upgrade() {
                this.reload_with_update();
            }
        });
        this
    }

    /// The id of the account the window is on, if it has one.
    pub fn account(&self) -> Option<String> {
        self.account.borrow().clone()
    }

    /// The account the window is on, while the app is still paired with it.
    fn pairing(&self) -> Option<RemotePairing> {
        let shell = self.shell.upgrade()?;
        shell.pairing(self.account.borrow().as_deref()?)
    }

    /// Puts the window on the account with this id, or on the pairing page
    /// for a new one.
    fn switch_account(self: &Rc<Self>, account: Option<String>) {
        *self.account.borrow_mut() = account;
        self.load();
    }

    /// Shows the window's account in the account switcher, which is there
    /// once the app has paired.
    pub fn show_account(&self) {
        let pairing = self.pairing();
        let id = pairing
            .as_ref()
            .map(|p| p.id().to_string())
            .unwrap_or_default();
        self.account_action.set_state(&id.to_variant());
        self.account_button
            .set_label(&pairing.map_or_else(|| "New account".to_string(), |p| p.label()));
        self.account_button.set_visible(
            self.shell
                .upgrade()
                .is_some_and(|shell| shell.has_pairings()),
        );
    }

    /// Loads the UI for the window's account, unless it is already showing
    /// for it, trying again while the server can't be reached.
    pub fn load(self: &Rc<Self>) {
        if let Some(loading) = self.loading.take() {
            loading.abort();
        }
        self.show_account();
        let pairing = self.pairing();
        self.preferences.set_enabled(pairing.is_some());
        let Some(pairing) = pairing else {
            self.show(State::Unpaired);
            return;
        };
        if let State::Ready(session) = &*self.state.borrow()
            && session.pairing == pairing
        {
            return;
        }
        self.show(State::Loading);
        let weak = Rc::downgrade(self);
        let loading = glib::spawn_future_local(async move {
            for attempt in 1..=ATTEMPTS {
                let result = RUNTIME
                    .spawn(WebAssets::load(pairing.clone()))
                    .await
                    .expect("loading the web UI doesn't panic");
                let Some(this) = weak.upgrade() else { return };
                match result {
                    Ok(assets) => {
                        this.show_ready(pairing, Arc::new(assets));
                        return;
                    }
                    Err(LoadError::Connection(ConnectionError::Unpaired)) => {
                        this.show(State::Unpaired);
                        return;
                    }
                    Err(err @ (LoadError::NoWebUI | LoadError::Malformed)) => {
                        this.show(State::Failed(err.to_string()));
                        return;
                    }
                    Err(err) if attempt == ATTEMPTS => {
                        this.show(State::Failed(err.to_string()));
                        return;
                    }
                    Err(_) => {}
                }
                drop(this);
                glib::timeout_future_seconds(1).await;
            }
        });
        *self.loading.borrow_mut() = Some(loading);
    }

    /// Fetches the newer build the server serves, and shows it in place of this one.
    fn reload_with_update(self: &Rc<Self>) {
        self.show(State::Loading);
        self.load();
    }

    fn show_ready(self: &Rc<Self>, pairing: RemotePairing, assets: Arc<WebAssets>) {
        let Some(shell) = self.shell.upgrade() else {
            return;
        };
        let weak = Rc::downgrade(self);
        let network = shell.network(&pairing);
        let session = WebUISession::new(pairing, assets, &network, move || {
            if let Some(this) = weak.upgrade() {
                this.offer_update();
            }
        });
        let view = &session.view;
        let window = self.window.downgrade();
        view.connect_title_notify(move |view| {
            let Some(window) = window.upgrade() else {
                return;
            };
            let title = view.title().filter(|title| !title.is_empty());
            window.set_title(Some(title.as_deref().unwrap_or("Cohesion")));
        });
        // A new document starts without it, so it is set again after each load.
        let header = self.header.downgrade();
        view.connect_load_changed(move |view, event| {
            if event != LoadEvent::Finished {
                return;
            }
            let Some(header) = header.upgrade() else {
                return;
            };
            let height = match header.height() {
                0 => header.measure(gtk::Orientation::Vertical, -1).1,
                height => height,
            };
            view.evaluate_javascript(
                &format!(
                    "document.documentElement.style.setProperty('--titlebar-inset', '{height}px')"
                ),
                None,
                None,
                None::<&gio::Cancellable>,
                |_| {},
            );
        });
        self.web.set_child(Some(view));
        self.show(State::Ready(session));
    }

    /// Offers the newer build the server serves, once a session finds it.
    fn offer_update(&self) {
        if self.update.is_enabled() {
            return;
        }
        self.update.set_enabled(true);
        let toast = adw::Toast::builder()
            .title("A new version of Cohesion is ready.")
            .button_label("Update and reload")
            .action_name("win.update")
            .timeout(0)
            .build();
        self.toasts.add_toast(toast);
    }

    fn show(&self, state: State) {
        let page = match &state {
            State::Loading => "loading",
            State::Unpaired => "pairing",
            State::Ready(_) => "web",
            State::Failed(message) => {
                self.failed.set_description(Some(message));
                "failed"
            }
        };
        if !matches!(state, State::Ready(_)) {
            self.web.set_child(None::<&gtk::Widget>);
            self.window.set_title(Some("Cohesion"));
        }
        self.update.set_enabled(false);
        self.stack.set_visible_child_name(page);
        *self.state.borrow_mut() = state;
    }
}
