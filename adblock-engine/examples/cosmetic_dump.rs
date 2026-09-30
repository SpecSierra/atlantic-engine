use adblock::Engine;
fn main() {
    let path = std::env::args().nth(1).expect("usage: cosmetic_dump <engine.dat> <url>");
    let url = std::env::args().nth(2).expect("url");
    let data = std::fs::read(&path).unwrap();
    let mut engine = Engine::default();
    engine.deserialize(&data).expect("deserialize failed");
    let r = engine.url_cosmetic_resources(&url);
    let mut v: Vec<&String> = r.hide_selectors.iter().collect();
    v.sort();
    for s in v { println!("{}", s); }
}
