//! Stands in for the web UI while there is no server to show it for:
//! registers this app with a server using the setup code it printed, under
//! a name that starts as the computer's.

use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use crate::{
    RUNTIME,
    pairing::{self, RemotePairing},
    shell::Shell,
};

pub fn new(shell: &Rc<Shell>) -> gtk::Widget {
    let name = adw::EntryRow::builder()
        .title("Name")
        .text(pairing::device_name())
        .build();
    let code = adw::EntryRow::builder().title("Setup code").build();
    let rows = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build();
    rows.append(&name);
    rows.append(&code);
    let pair = gtk::Button::builder()
        .label("Pair")
        .halign(gtk::Align::Center)
        .css_classes(["pill", "suggested-action"])
        .sensitive(false)
        .build();
    let error = gtk::Label::builder()
        .wrap(true)
        .selectable(true)
        .justify(gtk::Justification::Center)
        .css_classes(["error"])
        .visible(false)
        .build();
    let form = gtk::Box::new(gtk::Orientation::Vertical, 24);
    form.append(&rows);
    form.append(&pair);
    form.append(&error);
    let page = adw::StatusPage::builder()
        .icon_name("network-server-symbolic")
        .title("Pair with Cohesion")
        .description("Enter a setup code to connect this device to your Cohesion server.")
        .child(&adw::Clamp::builder().maximum_size(360).child(&form).build())
        .build();

    let can_pair = {
        let (name, code) = (name.clone(), code.clone());
        move || !code.text().trim().is_empty() && !name.text().trim().is_empty()
    };
    for row in [&name, &code] {
        let (pair, can_pair) = (pair.clone(), can_pair.clone());
        row.connect_changed(move |_| pair.set_sensitive(can_pair()));
    }

    let start = {
        let shell = Rc::downgrade(shell);
        let (name, code, pair, error) = (name.clone(), code.clone(), pair.clone(), error.clone());
        move || {
            if !can_pair() || pair.child().is_some_and(|child| child.is::<adw::Spinner>()) {
                return;
            }
            pair.set_child(Some(&adw::Spinner::new()));
            error.set_visible(false);
            let setup_code = code.text().trim().to_string();
            let device = name.text().trim().to_string();
            let (shell, code, pair, error) =
                (shell.clone(), code.clone(), pair.clone(), error.clone());
            glib::spawn_future_local(async move {
                let result = RUNTIME
                    .spawn(async move { RemotePairing::register(&setup_code, &device).await })
                    .await
                    .expect("pairing doesn't panic");
                pair.set_label("Pair");
                match result {
                    Ok(pairing) => {
                        code.set_text("");
                        if let Some(shell) = shell.upgrade() {
                            shell.set_pairing(Some(pairing));
                        }
                    }
                    Err(err) => {
                        error.set_label(&err.to_string());
                        error.set_visible(true);
                    }
                }
            });
        }
    };
    let start = Rc::new(start);
    {
        let start = start.clone();
        pair.connect_clicked(move |_| start());
    }
    code.connect_entry_activated(move |_| start());
    // The name is usually right as it is; the code is what to type.
    page.connect_map(move |_| {
        code.grab_focus();
    });
    page.upcast()
}
