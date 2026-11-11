//! A window's settings: the account it is on, and unpairing from it.

use std::rc::Rc;

use adw::prelude::*;

use crate::{pairing::RemotePairing, shell::Shell};

pub fn present(shell: &Rc<Shell>, pairing: &RemotePairing, parent: &impl IsA<gtk::Widget>) {
    let dialog = adw::PreferencesDialog::builder()
        .title("Preferences")
        .build();
    let server = adw::PreferencesGroup::builder().title("Account").build();
    let name = adw::ActionRow::builder()
        .title("Name")
        .subtitle(pairing.label())
        .build();
    name.add_css_class("property");
    server.add(&name);
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
    let id = pairing.id().to_string();
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
        let (shell, id) = (shell.clone(), id.clone());
        let closing = dialog.downgrade();
        confirm.connect_response(Some("unpair"), move |_, _| {
            if let Some(shell) = shell.upgrade() {
                shell.remove_pairing(&id);
            }
            if let Some(dialog) = closing.upgrade() {
                dialog.close();
            }
        });
        confirm.present(Some(&dialog));
    });
    dialog.present(Some(parent));
}
