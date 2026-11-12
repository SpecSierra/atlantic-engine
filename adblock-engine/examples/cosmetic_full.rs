// cosmetic_full DAT URL OUT_CSS OUT_JS [RESOURCES_JSON]: what the engine asks a page of URL to hide and inject.
use adblock::Engine;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mut engine = Engine::default();
    engine.deserialize(&std::fs::read(&a[1]).unwrap()).unwrap();
    if let Some(path) = a.get(5) {
        let resources: Vec<adblock::resources::Resource> = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        engine.use_resources(resources);
    }
    let r = engine.url_cosmetic_resources(&a[2]);
    let mut css = String::new();
    let mut n = 0;
    for s in &r.hide_selectors { css.push_str(&format!("{} {{ display: none !important; }}\n", s)); n += 1; }
    std::fs::write(&a[3], css).unwrap();
    std::fs::write(&a[4], &r.injected_script).unwrap();
    println!("hide selectors: {}, injected script: {} bytes, generichide: {}, exceptions: {}", n, r.injected_script.len(), r.generichide, r.exceptions.len());
}
