//! Cohesion for Linux: a WebUI harness in GTK 4 and libadwaita. It pairs
//! with a cohesiond natively, fetches the web UI's bundle from it, serves
//! the bundle to a WebKitGTK web view at `cohesion://app/` and stands in
//! for the page's session API (`#token=`, `/client`, `/connect`), as
//! CohesionWebKit does for the Mac and iPad.

mod assets;
mod bridge;
mod connection;
mod pairing;
mod pairing_page;
mod preferences;
mod serving;
mod session;
mod shell;
mod window;

use std::{path::PathBuf, sync::LazyLock};

use adw::prelude::*;
use gtk::glib;

const APP_ID: &str = "com.hellocohesion.Cohesion";
/// The directory this app's files go in, under each XDG base directory.
const DIRECTORY: &str = "cohesion-gtk";

/// Where networking runs; GTK keeps the main thread.
pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("the networking runtime starts")
});

pub fn config_dir() -> PathBuf {
    glib::user_config_dir().join(DIRECTORY)
}

pub fn cache_dir() -> PathBuf {
    glib::user_cache_dir().join(DIRECTORY)
}

pub fn data_dir() -> PathBuf {
    glib::user_data_dir().join(DIRECTORY)
}

fn main() -> glib::ExitCode {
    // GTK's GL renderer takes the web view's frames as they are. Its Vulkan
    // renderer, the default, can't import them on some drivers (NVIDIA's,
    // for one) and copies each one back through GL instead, on the main
    // thread: a hover then takes hundreds of milliseconds, and an animation
    // keeps more than two cores busy. A renderer set in the environment wins.
    if std::env::var_os("GSK_RENDERER").is_none() {
        // SAFETY: nothing else runs yet; the networking runtime starts later.
        unsafe { std::env::set_var("GSK_RENDERER", "ngl") };
    }
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_startup(|app| {
        glib::set_application_name("Cohesion");
        let css = gtk::CssProvider::new();
        css.load_from_string(include_str!("style.css"));
        gtk::style_context_add_provider_for_display(
            &gtk::gdk::Display::default().expect("GTK has a display"),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        shell::Shell::start(app);
    });
    app.run()
}
