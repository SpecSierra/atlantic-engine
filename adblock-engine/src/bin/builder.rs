use std::env;
use std::fs;

use adblock::engine::Engine;
use adblock::lists::{FilterSet, ParseOptions};

// Assemble the runtime resources JSON: uBO scriptlets (old pre-ES-module
// format — the only one adblock-rust can parse; pinned in versions.env) merged
// with Brave's adblock-resources dist (redirect surrogates). Consumed at
// runtime via atlantic_adblock_use_resources_json; NOT part of engine.dat.
fn build_resources(output: &str, scriptlets_path: &str, brave_json_path: &str) {
    #[allow(deprecated)]
    let mut resources = adblock::resources::resource_assembler::assemble_scriptlet_resources(
        std::path::Path::new(scriptlets_path),
    );
    let scriptlet_count = resources.len();
    let brave_json = fs::read_to_string(brave_json_path).unwrap_or_else(|e| {
        eprintln!("failed to read {}: {}", brave_json_path, e);
        std::process::exit(1);
    });
    let brave: Vec<adblock::resources::Resource> = serde_json::from_str(&brave_json)
        .unwrap_or_else(|e| {
            eprintln!("failed to parse {}: {}", brave_json_path, e);
            std::process::exit(1);
        });
    let brave_count = brave.len();
    resources.extend(brave);
    let out = serde_json::to_string(&resources).expect("serialize resources");
    fs::write(output, &out).unwrap_or_else(|e| {
        eprintln!("failed to write {}: {}", output, e);
        std::process::exit(1);
    });
    println!(
        "Wrote {} resources ({} uBO scriptlets + {} Brave) to {}",
        scriptlet_count + brave_count,
        scriptlet_count,
        brave_count,
        output
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() >= 2 && args[1] == "--resources" {
        if args.len() != 5 {
            eprintln!("Usage: builder --resources <output.json> <scriptlets.js> <brave-resources.json>");
            std::process::exit(1);
        }
        build_resources(&args[2], &args[3], &args[4]);
        return;
    }
    if args.len() < 3 {
        eprintln!("Usage: builder <output.dat> <list1.txt> [list2.txt ...]");
        eprintln!("       builder --resources <output.json> <scriptlets.js> <brave-resources.json>");
        std::process::exit(1);
    }

    let output = &args[1];
    let mut filter_set = FilterSet::new(true);

    for path in &args[2..] {
        let text = fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("failed to read {}: {}", path, e);
            std::process::exit(1);
        });
        let fmt = if path.contains("hosts") {
            adblock::lists::FilterFormat::Hosts
        } else {
            adblock::lists::FilterFormat::Standard
        };
        let opts = ParseOptions {
            format: fmt,
            ..ParseOptions::default()
        };
        filter_set.add_filter_list(&text, opts);
    }

    let engine = Engine::from_filter_set(filter_set, true);
    let data = engine.serialize();
    fs::write(output, &data).unwrap_or_else(|e| {
        eprintln!("failed to write {}: {}", output, e);
        std::process::exit(1);
    });

    println!("Wrote {} bytes to {}", data.len(), output);
}
