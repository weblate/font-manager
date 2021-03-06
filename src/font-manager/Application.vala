/* Application.vala
 *
 * Copyright (C) 2009 - 2020 Jerry Casiano
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.
 *
 * If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
*/

namespace FontManager {

    public static DatabaseProxy? db = null;
    public static GLib.Settings? settings = null;
    public static FontManager.Reject? reject = null;
    public static FontModel? font_model = null;
    public static MainWindow? main_window = null;
    public static StringSet available_font_families = null;
    public static StringSet temp_files = null;

    internal void clear_resources () {
        clear_application_fonts();
        settings = null;
        reject = null;
        if (temp_files != null)
            foreach (string path in temp_files)
                remove_directory(File.new_for_path(path));
        temp_files = null;
        return;
    }

    [DBus (name = "org.gnome.FontManager")]
    public class Application: Gtk.Application  {

        [DBus (visible = false)]
        public bool update_in_progress { get; private set; default = false; }

        const OptionEntry[] options = {
            { "about", 'a', 0, OptionArg.NONE, null, "About the application", null },
            { "version", 'v', 0, OptionArg.NONE, null, "Show application version", null },
            { "install", 'i', 0, OptionArg.NONE, null, "Space separated list of files to install.", null },
            { "enable", 'e', 0, OptionArg.NONE, null, "Space separated list of font families to enable", null },
            { "disable", 'd', 0, OptionArg.NONE, null, "Space separated list of font families to disable", null },
            { "list", 'l', 0, OptionArg.NONE, null, "List available font families.", null },
            { "list-full", 0, 0, OptionArg.NONE, null, "Full listing including face information. (JSON)", null },
            { "update", 'u', 0, OptionArg.NONE, null, "Update application database", null },
            { "", 0, 0, OptionArg.FILENAME_ARRAY, null, null, null },
            { null }
        };

        uint dbus_id = 0;
        SearchProvider? gs_search_provider = null;

        public Application (string app_id, ApplicationFlags app_flags) {
            Object(application_id : app_id, flags : app_flags);
            add_main_option_entries(options);
        }

        public override void startup () {
            base.startup();
            settings = get_gsettings(BUS_ID);
            available_font_families = new StringSet();
            temp_files = new StringSet();
            reject = new Reject();
            reject.load();
            db = new DatabaseProxy();
            db.update_started.connect(() => { update_in_progress = true; });
            db.update_complete.connect(() => {
                update_in_progress = false;
                enable_user_font_configuration(true);
            });
            SimpleAction quit = new SimpleAction("quit", null);
            add_action(quit);
            quit.activate.connect(() => {
                if (main_window != null)
                    main_window.close();
                Idle.add(() => { this.quit(); return GLib.Source.REMOVE; });
            });
            const string? [] accels = {"<Ctrl>q", null };
            set_accels_for_action("app.quit", accels);
            return;
        }

        public override void open (File [] files, string hint) {
            int index = hint != "" ? int.parse(hint) : 0;
            try {
                DBusConnection conn = Bus.get_sync(BusType.SESSION);
                conn.call_sync(FontViewer.BUS_ID,
                                FontViewer.BUS_PATH,
                                FontViewer.BUS_ID,
                                "ShowUri",
                                new Variant("(si)", files[0].get_uri(), index),
                                null,
                                DBusCallFlags.NONE,
                                -1,
                                null);
            } catch (Error e) {
                critical("Method call to %s failed : %s", FontViewer.BUS_ID, e.message);
            }
            return;
        }

        public override int command_line (ApplicationCommandLine cl) {
            hold();

            VariantDict options = cl.get_options_dict();
            StringSet? filelist = get_command_line_files(cl);

            if (options.contains("install") || options.contains("update")) {
                if (options.contains("install") && filelist != null) {
                    var installer = new Library.Installer();
                    installer.progress.connect((m, p, t) => {
                        var data = new ProgressData(m, p, t);
                        data.print();
                    });
                    stdout.printf("Installing Font Files\n");
                    installer.process_sync(filelist);
                    stdout.printf("\n");
                }
                ensure_reject();
                update_font_configuration();
                try {
                    load_user_font_resources(reject.get_rejected_files(), null);
                } catch (Error e) {
                    critical(e.message);
                }
                DatabaseType [] db_types = {
                    DatabaseType.FONT,
                    DatabaseType.METADATA,
                    DatabaseType.ORTHOGRAPHY
                };
                foreach (var type in db_types) {
                    try {
                        stdout.printf("Updating Database - %s\n", Database.get_type_name(type));
                        update_database_sync(get_database(type), type, ProgressData.print, null);
                        stdout.printf("\n");
                    } catch (Error e) {
                        critical(e.message);
                        return e.code;
                    }
                }
            } else if (filelist != null) {
                File [] files = { File.new_for_path(filelist[0]) };
                open(files, "preview");
            } else {
                activate();
            }

            release();
            return 0;
        }

        void ensure_reject () {
            if (reject == null) {
                reject = new Reject();
                reject.load();
            }
            return;
        }

        public string list () throws GLib.DBusError, GLib.IOError {
            load_user_font_resources(null, null);
            GLib.List <string> families = list_available_font_families();
            assert(families.length() > 0);
            StringBuilder builder = new StringBuilder();
            foreach (string family in families)
                builder.append("%s\n".printf(family));
            return builder.str;
        }

        public string list_full () throws GLib.DBusError, GLib.IOError {
            ensure_reject();
            update_font_configuration();
            try {
                load_user_font_resources(reject.get_rejected_files(), null);
            } catch (Error e) {
                critical(e.message);
            }
            Json.Object available_fonts = get_available_fonts(null);
            Json.Array sorted_fonts = sort_json_font_listing(available_fonts);
            return print_json_array(sorted_fonts, true);
        }

        public void enable (string [] families) throws GLib.DBusError, GLib.IOError {
            ensure_reject();
            foreach (var family in families)
                if (family in reject)
                    reject.remove(family);
            reject.save();
            return;
        }

        public void disable (string [] families) throws GLib.DBusError, GLib.IOError {
            ensure_reject();
            foreach (var family in families)
                reject.add(family);
            reject.save();
            return;
        }

        public void install (string [] filepaths) throws GLib.DBusError, GLib.IOError {
            StringSet filelist = new StringSet();
            foreach (var path in filepaths)
                filelist.add(path);
            var installer = new Library.Installer();
            installer.process_sync(filelist);
            return;
        }

        public override int handle_local_options (VariantDict options) {

            int exit_status = -1;

            if (options.contains("version")) {
                print_version();
                return 0;
            }

            if (options.contains("about")) {
                print_about();
                return 0;
            }

            ensure_reject();

            if (options.contains("enable")) {
                var accept = get_command_line_input(options);
                return_val_if_fail(accept != null, -1);
                foreach (var family in accept)
                    if (family in reject)
                        reject.remove(family);
                reject.save();
                exit_status = 0;
            }

            if (options.contains("disable")) {
                var rejects = get_command_line_input(options);
                return_val_if_fail(rejects != null, -1);
                foreach (var family in rejects)
                    reject.add(family);
                reject.save();
                exit_status = 0;
            }

            if (options.contains("list")) {
                try {
                    stdout.printf(list());
                } catch (Error e) {
                    critical(e.message);
                    return e.code;
                }
                exit_status = 0;
            }

            if (options.contains("list-full")) {
                try {
                    stdout.printf("\n%s\n\n", list_full());
                } catch (Error e) {
                    critical(e.message);
                    return e.code;
                }
                exit_status = 0;
            }

            return exit_status;
        }

        async void refresh_async () {
            SourceFunc callback = refresh_async.callback;
            ThreadFunc <bool> run_in_thread = () => {
                enable_user_font_configuration(false);
                update_font_configuration();
                try {
                    load_user_font_resources(reject.get_rejected_files(), null);
                } catch (Error e) {
                    critical(e.message);
                }
                Json.Object available_fonts = get_available_fonts(null);
                db.update();
                Json.Array sorted_fonts = sort_json_font_listing(available_fonts);
                if (main_window != null)
                    main_window.model = null;
                font_model.source_array = sorted_fonts;
                if (main_window != null)
                    main_window.model = font_model;
                available_font_families.clear();
                foreach (string family in available_fonts.get_members())
                    available_font_families.add(family);
                Idle.add((owned) callback);
                return true;
            };
            new Thread <bool> ("refresh_async", (owned) run_in_thread);
            yield;
            return;
        }

        [DBus (visible = false)]
        public void refresh () {
            if (update_in_progress)
                return;
            update_in_progress = true;
            refresh_async.begin((obj, res) => { refresh_async.end(res); });
            return;
        }

        protected override void activate () {
            if (main_window == null) {
                main_window = new MainWindow();
                add_window(main_window);
                db.set_progress_callback((data) => {
                    data.ref();
                    main_window.titlebar.progress.database(data);
                    data.unref();
                    return GLib.Source.REMOVE;
                });
            }
            main_window.present_with_time(Gdk.CURRENT_TIME);
            refresh();
            return;
        }

        [DBus (visible = false)]
        public new void quit () {
            /* Try to prevent noise during memcheck */
            clear_resources();
            base.quit();
            return;
        }

        [DBus (visible = false)]
        public void import () {
            import_user_data();
            Idle.add(() => {
                refresh();
                return GLib.Source.REMOVE;
            });
            return;
        }

        [DBus (visible = false)]
        public void export () {
            export_user_data();
            return;
        }

        [DBus (visible = false)]
        public void about () {
            Gtk.show_about_dialog(main_window,
                                "program-name", About.DISPLAY_NAME,
                                "logo-icon-name", About.ICON,
                                "version", About.VERSION,
                                "copyright", About.COPYRIGHT,
                                "comments", About.COMMENT,
                                "website", About.HOMEPAGE,
                                "authors", About.AUTHORS,
                                "license", About.LICENSE,
                                "translator-credits", About.TRANSLATORS,
                                null);
            return;
        }

        [DBus (visible = false)]
        public void help () {
            try {
                Gtk.show_uri_on_window(main_window, "help:%s".printf(Config.PACKAGE_NAME), Gdk.CURRENT_TIME);
            } catch (Error e) {
                critical("There was an error displaying help contents : %s", e.message);
            }
            return;
        }

        [DBus (visible = false)]
        public void shortcuts () {
            string ui = Path.build_path("/", BUS_PATH, "ui", "font-manager-shortcuts-window.ui");
            var builder = new Gtk.Builder.from_resource(ui);
            var shortcuts_window = builder.get_object("shortcuts-window") as Gtk.Window;
            shortcuts_window.delete_event.connect(() => {
                shortcuts_window.destroy();
                return true;
            });
            shortcuts_window.set_transient_for(main_window);
            shortcuts_window.show();
            return;
        }

        public override bool dbus_register (DBusConnection conn, string path) throws Error {
            bool result = base.dbus_register(conn, path);
            dbus_id = conn.register_object (BUS_PATH, this);
            if (dbus_id == 0)
                critical("Could not register Font Manager service ");
            if (gs_search_provider == null)
                gs_search_provider = new SearchProvider();
            gs_search_provider.dbus_register(conn);
            return result;
        }

        public override void dbus_unregister (DBusConnection conn, string path) {
            if (dbus_id != 0)
                conn.unregister_object(dbus_id);
            gs_search_provider.dbus_unregister(conn);
            base.dbus_unregister(conn, path);
            return;
        }

        public static int main (string [] args) {
            GLib.Intl.bindtextdomain(Config.PACKAGE_NAME, null);
            GLib.Intl.bind_textdomain_codeset(Config.PACKAGE_NAME, null);
            GLib.Intl.textdomain(Config.PACKAGE_NAME);
            GLib.Intl.setlocale(GLib.LocaleCategory.ALL, null);
            Environment.set_application_name(About.DISPLAY_NAME);
            Gtk.init(ref args);
            if (update_declined())
                return 0;
            set_application_style();
            ApplicationFlags FLAGS = (ApplicationFlags.HANDLES_OPEN |
                                      ApplicationFlags.HANDLES_COMMAND_LINE);
            return new Application(BUS_ID, FLAGS).run(args);
        }

    }

    FontManager.Application get_default_application () {
        return ((FontManager.Application) GLib.Application.get_default());
    }

}
