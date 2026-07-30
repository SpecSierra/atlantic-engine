use adblock::{Engine, request::Request};
fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let mut engine = Engine::default();
    engine.deserialize(&data).unwrap();
    let u = "https://www.pornhub.com/_xa/deep_click?h=abc&url=x";
    let s = "https://www.pornhub.com/";
    let broken = Request::preparsed(u, "", s, "document", false, "GET");
    let fixed = Request::new(u, s, "document", "GET").unwrap();
    println!("preparsed-empty-host matched={}", matched(&engine.check_network_request(&broken)));
    println!("request-new         matched={}", matched(&engine.check_network_request(&fixed)));
}

/// 0.13 dropped `BlockerResult::matched`; upstream's definition was
/// `exception.is_none() && (filter.is_some() || matched_rule)`, and `filter`
/// now folds in the matched_rule fallback.
fn matched(r: &adblock::blocker::BlockerResult) -> bool {
    r.exception.is_none() && r.filter.is_some()
}
