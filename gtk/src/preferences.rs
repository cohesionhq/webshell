//! The app's settings: the server it paired with, and unpairing from it.

use std::rc::Rc;

use adw::prelude::*;

use crate::shell::Shell;

pub fn present(shell: &Rc<Shell>, parent: &impl IsA<gtk::Widget>) {
    let Some(pairing) = shell.pairing() else {
        return;
    };
    let dialog = adw::PreferencesDialog::builder()
        .title("Preferences")
        .build();
    let server = adw::PreferencesGroup::builder().title("Server").build();
    let address = adw::ActionRow::builder()
        .title("Address")
        .subtitle(pairing.address())
        .subtitle_selectable(true)
        .build();
    address.add_css_class("property");
    server.add(&address);
    let unpair = adw::ButtonRow::builder().title("Unpair").build();
    unpair.add_css_class("destructive-action");
    let actions = adw::PreferencesGroup::new();
    actions.add(&unpair);
    let page = adw::PreferencesPage::new();
    page.add(&server);
    page.add(&actions);
    dialog.add(&page);

    let shell = Rc::downgrade(shell);
    let weak = dialog.downgrade();
    unpair.connect_activated(move |_| {
        let Some(dialog) = weak.upgrade() else { return };
        let confirm = adw::AlertDialog::new(
            Some("Unpair from this server?"),
            Some("You’ll need a new setup code to pair again."),
        );
        confirm.add_responses(&[("cancel", "Cancel"), ("unpair", "Unpair")]);
        confirm.set_response_appearance("unpair", adw::ResponseAppearance::Destructive);
        confirm.set_close_response("cancel");
        let shell = shell.clone();
        let closing = dialog.downgrade();
        confirm.connect_response(Some("unpair"), move |_, _| {
            if let Some(shell) = shell.upgrade() {
                shell.set_pairing(None);
            }
            if let Some(dialog) = closing.upgrade() {
                dialog.close();
            }
        });
        confirm.present(Some(&dialog));
    });
    dialog.present(Some(parent));
}
