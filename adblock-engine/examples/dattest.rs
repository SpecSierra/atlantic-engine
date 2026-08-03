use adblock::{Engine, request::Request};
fn main() {
    let path = std::env::args().nth(1).expect("usage: dattest <engine.dat>");
    let data = std::fs::read(&path).unwrap();
    let mut engine = Engine::default();
    engine.deserialize(&data).expect("deserialize failed");
    let u = "https://www.pornhub.com/_xa/deep_click?h=abc&url=https%3A%2F%2Fplay.epicrespin.com";
    let s = "https://www.pornhub.com/";
    for ty in ["document", "main_frame", "xhr"] {
        let req = Request::new(u, s, ty, "GET").unwrap();
        let r = engine.check_network_request(&req);
        println!("type={} matched={} filter={:?}", ty, matched(&r), r.filter);
    }
}

/// 0.13 dropped `BlockerResult::matched`; upstream's definition was
/// `exception.is_none() && (filter.is_some() || matched_rule)`, and `filter`
/// now folds in the matched_rule fallback.
fn matched(r: &adblock::blocker::BlockerResult) -> bool {
    r.exception.is_none() && r.filter.is_some()
}
