// SPDX-FileCopyrightText: 2026 Patrick Quinn
// SPDX-License-Identifier: Apache-2.0

use std::path::PathBuf;

use cxx_qt_build::{CxxQtBuilder, QmlModule};

// Links Keel's SailfishApp library (libkeel-sailfishapp) for cpp/launcher.cpp;
// brings `Path` and `PathBuf` into scope.
include!("../../tools/keel-launcher/link_sailfishapp.rs");
// Compiles the UI's QML into the app (tools/keel-launcher/precompile_qml.rs).
include!("../../tools/keel-launcher/precompile_qml.rs");

fn main() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let sailfishapp_include = link_keel_sailfishapp(&repo);

    // `Shipwright.Reef 1.0`: the module the QML in ui/ imports. It
    // holds only the Rust types; the UI's own .qml files are installed to
    // /usr/share/shipwright-reef/qml and loaded from disk.
    let builder = CxxQtBuilder::new_qml_module(QmlModule::new("Shipwright.Reef").version(1, 0))
        .qt_module("Quick")
        .qt_module("Network")
        .files(["src/bridge.rs"])
        // Creates the list models as children of the Reef object; CXX-Qt
        // cannot `new` a QObject from Rust.
        .cpp_file("cpp/factory.cpp")
        .include_dir(sailfishapp_include)
        .cpp_file("cpp/launcher.cpp");

    // GCC 16 warns (-Wsfinae-incomplete) inside Qt's own headers (qchar.h,
    // qmetatype.h probe completeness on purpose); older compilers ignore
    // the flag.
    // SAFETY: a warning flag only; it changes no generated code or ABI.
    let builder = unsafe {
        builder.cc_builder(|cc| {
            cc.flag_if_supported("-Wno-sfinae-incomplete");
        })
    };

    builder.build();

    // The UI's QML and JavaScript, compiled ahead of time for where the
    // package installs them.
    precompile_app_qml(
        &repo.join("apps/reef/ui"),
        "/usr/share/shipwright-reef/qml",
        &[],
    );

    // Keel Actions (ADR-0018): actions.json and the D-Bus files from the QML
    // declarations, into $OUT_DIR (keel::manifest!() in src/lib.rs) and
    // target/release/keel-actions/<app-id>/ for the package.
    let output = keel_actions_codegen::Config {
        qml: vec![repo.join("apps/reef/ui")],
        desktop: Some(repo.join("apps/reef/shipwright-reef.desktop")),
        // No [X-Sailjail] names (unsandboxed): the app ID is given.
        app_id: Some("org.marathonos.reef".into()),
        ..Default::default()
    }
    .build_script();

    // Write the packaging artefacts next to the release binary, using the
    // same target directory Cargo will use. The APK package step requires
    // these files, so do not silently ignore a failure to write them.
    let target_dir = std::env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo.join("apps/reef/target"));
    let packaged = target_dir
        .join("release")
        .join("keel-actions")
        .join(&output.app.app_id);

    keel_actions_codegen::write(&output.artefacts, &packaged).unwrap_or_else(|error| {
        panic!(
            "keel actions: cannot write packaging artefacts to {}: {error}",
            packaged.display()
        )
    });

    println!(
        "cargo:warning=keel actions: packaged artefacts in {}",
        packaged.display()
    );
}
