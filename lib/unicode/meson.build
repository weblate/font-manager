
unicode_gresource_xml_file = files('unicode-gresources.xml')

unicode_gresource = gnome.compile_resources('unicode_gresource', unicode_gresource_xml_file)

unicode_sources = [
    unicode_gresource[0],
    'unicode-codepoint-list.c',
    'unicode-codepoint-list.h',
    'unicode-character-map.c',
    'unicode-character-map.h',
    'unicode-character-map-zoom-window.c',
    'unicode-character-map-zoom-window.h',
    'unicode-info.c',
    'unicode-info.h',
    'unicode-search-bar.c',
    'unicode-search-bar.h'
]

libunicode = both_libraries('unicode',
                            unicode_sources,
                            dependencies: base_deps)

unicode_gir = gnome.generate_gir(libunicode,
                                sources: unicode_sources,
                                namespace: 'Unicode',
                                nsversion: meson.project_version(),
                                header: 'unicode-info.h',
                                includes: ['Pango-1.0', 'Gdk-3.0', 'Gtk-3.0'])

configure_file(
    input: 'Unicode.metadata',
    output: 'Unicode-@0@.metadata'.format(meson.project_version()),
    copy: true
)

unicode_vapi = gnome.generate_vapi('Unicode-@0@'.format(meson.project_version()),
                                    sources: unicode_gir[0],
                                    metadata_dirs: meson.current_build_dir(),
                                    packages: ['glib-2.0', 'pango', 'gdk-3.0', 'gtk+-3.0'])
