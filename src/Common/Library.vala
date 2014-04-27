/* Library.vala
 *
 * Copyright © 2009 - 2014 Jerry Casiano
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
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Author:
 *  Jerry Casiano <JerryCasiano@gmail.com>
 */

namespace FontManager {

    namespace Library {

        public static Gee.HashMap <string, string>? fail = null;
        public static Gee.ArrayList <File>? installed = null;
        public static ProgressCallback? progress = null;

        public struct InstallData {
            public File file;
            public FontConfig.Font font;
            public FontInfo fontinfo;

            public InstallData (File file, string? rmdir = null) {
                this.file = file;
                font = FontConfig.get_font_from_file(file.get_path());
                fontinfo = new FontInfo(file.get_path());
            }
        }

        public struct Install {

            internal string USER_FONT_DIR;

            public Install.from_file_array (File? [] files) {
                USER_FONT_DIR = Path.build_filename(Environment.get_user_data_dir(), "fonts");
                var _files = new Gee.ArrayList <File> ();
                foreach (var file in files) {
                    if (file == null)
                        break;
                    _files.add(file);
                }
                process_files(_files);
            }

            public Install.from_path_array (string [] paths) {
                USER_FONT_DIR = Path.build_filename(Environment.get_user_data_dir(), "fonts");
                var files = new Gee.ArrayList <File> ();
                foreach (var path in paths) {
                    if (path == null)
                        break;
                    files.add(File.new_for_path(path));
                }
                process_files(files);
            }

            public Install.from_uri_array (string [] uris) {
                USER_FONT_DIR = Path.build_filename(Environment.get_user_data_dir(), "fonts");
                var files = new Gee.ArrayList <File> ();
                foreach (var uri in uris) {
                    if (uri == null)
                        break;
                    files.add(File.new_for_uri(uri));
                }
                process_files(files);
            }

            internal void try_copy (File original, File copy) {
                try {
                    original.copy(copy, FileCopyFlags.OVERWRITE | FileCopyFlags.ALL_METADATA);
                } catch (Error e) {
                    string path = original.get_path();
                    if (fail == null)
                        fail = new Gee.HashMap <string, string> ();
                    fail[path] = e.message;
                    warning("%s : %s", e.message, path);
                }
                return;
            }

            internal void install_font (InstallData data) {
                if (data.font == null || data.fontinfo == null) {
                    if (fail == null)
                        fail = new Gee.HashMap <string, string> ();
                    fail[data.file.get_path()] = "Failed to create FontInfo";
                    warning("Failed to create FontInfo :: %s", data.file.get_path());
                    return;
                }
                string dest = Path.build_filename(USER_FONT_DIR,
                                                    data.fontinfo.vendor,
                                                    data.fontinfo.filetype,
                                                    data.font.family);
                DirUtils.create_with_parents(dest, 0755);
                string filename = data.font.to_filename();
                string filepath = Path.build_filename(dest, "%s%s".printf(filename, get_file_extension(data.file.get_path())));
                var file = File.new_for_path(filepath);
                try_copy(data.file, file);
                /* XXX */
                if (data.fontinfo.filetype == "Type 1") {
                    foreach (var ext in FONT_METRICS) {
                        string par = data.file.get_parent().get_path();
                        FileInfo inf = data.file.query_info(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                        string name = inf.get_name().split_set(".")[0] + ext;
                        string poss = Path.build_filename(par, name);
                        File f = File.new_for_path(poss);
                        if (f.query_exists()) {
                            string path = Path.build_filename(dest, filename + ext);
                            File _f = File.new_for_path(path);
                            try_copy(f, _f);
                        }
                    }
                }
                if (installed == null)
                    installed = new Gee.ArrayList <File> ();
                installed.add(data.file);
                return;
            }

            internal void process_file (File file) {
                string filepath = file.get_path();
                foreach (var ext in FONT_METRICS)
                    if (filepath.has_suffix(ext))
                        return;
                install_font(InstallData(file));
                return;
            }

            internal void process_directory (File dir) {
                try {
                    FileInfo fileinfo;
                    var archive_manager = new ArchiveManager();
                    var attrs = "%s,%s,%s".printf(FileAttribute.STANDARD_NAME, FileAttribute.STANDARD_CONTENT_TYPE, FileAttribute.STANDARD_TYPE);
                    var enumerator = dir.enumerate_children(attrs, FileQueryInfoFlags.NONE);
                    var supported_archives = archive_manager.get_supported_types();
                    int processed = 0;
                    int total = 0;
                    while ((fileinfo = enumerator.next_file ()) != null)
                        total++;
                    enumerator = dir.enumerate_children(attrs, FileQueryInfoFlags.NONE);
                    while ((fileinfo = enumerator.next_file ()) != null) {
                        string content_type = fileinfo.get_content_type();
                        if (fileinfo.get_file_type() == FileType.DIRECTORY) {
                            process_directory(dir.get_child(fileinfo.get_name()));
                        } else {
                            if (content_type.contains("font")) {
                                process_file(dir.get_child(fileinfo.get_name()));
                            } else if (content_type in supported_archives) {
                                if (content_type in ARCHIVE_IGNORE_LIST)
                                    continue;
                                process_archive(archive_manager, dir.get_child(fileinfo.get_name()));
                            } else if (content_type == "application/octet-stream") {
                                bool metrics_file = false;
                                foreach (var ext in FONT_METRICS) {
                                    if (fileinfo.get_name().has_suffix(ext)) {
                                        metrics_file = true;
                                        break;
                                    }
                                }
                                if (metrics_file)
                                    continue;
                                warning("Ignoring font metrics file : %s", dir.get_child(fileinfo.get_name()).get_path());
                            }// else
//                                warning("Ignoring unsupported file : %s", dir.get_child(fileinfo.get_name()).get_path());
                        }
                        processed++;
                        if (progress != null)
                            progress("Processing files...", processed, total);
                    }
                } catch (Error e) {
                    warning("%s :: %s", e.message, dir.get_path());
                }
                return;
            }

            internal void process_archive (ArchiveManager archive_manager, File file) {
                string? _tmpdir = DirUtils.make_tmp(TMPL);
                if (_tmpdir == null) {
                    if (fail == null)
                        fail = new Gee.HashMap <string, string> ();
                    fail[file.get_path()] = "Failed to create temporary directory";
                    return;
                }
                var tmpdir = File.new_for_path(_tmpdir);
                try {
                    archive_manager.extract(file.get_uri(), tmpdir.get_uri());
                    process_directory(tmpdir);
                } catch (Error e) {
                    if (fail == null)
                        fail = new Gee.HashMap <string, string> ();
                    fail[file.get_path()] = "Failed to extract archive";
                }
                remove_directory(tmpdir);
                return;
            }

            internal void process_files (Gee.ArrayList <File> filelist) {
                var archive_manager = new ArchiveManager();
                var supported_archives = archive_manager.get_supported_types();
                int total = filelist.size;
                int processed = 0;
                foreach (var file in filelist) {
                    var attrs = "%s,%s".printf(FileAttribute.STANDARD_CONTENT_TYPE, FileAttribute.STANDARD_TYPE);
                    var fileinfo = file.query_info(attrs, FileQueryInfoFlags.NONE, null);
                    string content_type = fileinfo.get_content_type();
                    if (fileinfo.get_file_type() == FileType.DIRECTORY) {
                        process_directory(file);
                    } else if (content_type.contains("font")) {
                        process_file(file);
                    } else if (content_type in supported_archives) {
                        process_archive(archive_manager, file);
                    }// else
//                        warning("Ignoring unsupported file : %s", file.get_path());
                    processed++;
                    if (progress != null)
                        progress("Processing files...", processed, total);
                }
                return;
            }
        }

    }

}