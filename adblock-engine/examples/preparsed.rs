use adblock::{Engine, request::Request};
fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let mut engine = Engine::default();
    engine.deserialize(&data).unwrap();
    let u = "https://www.pornhub.com/_xa/deep_click?h=abc&url=x";
    let s = "https://www.pornhub.com/";
    let broken = Request::preparsed(u, "", s, "document", false);
    let fixed = Request::new(u, s, "document").unwrap();
    println!("preparsed-empty-host matched={}", engine.check_network_request(&broken).matched);
    println!("request-new         matched={}", engine.check_network_request(&fixed).matched);
}
