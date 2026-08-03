use adblock::{Engine, FilterSet, lists::ParseOptions, request::Request};
fn check(rules: &[&str], url: &str, src: &str, ty: &str) {
    let mut fs = FilterSet::new(false);
    // 0.13 removed FilterSet::add_filters; a joined list text is the equivalent.
    fs.add_filter_list(rules.join("\n"), ParseOptions::default());
    let engine = Engine::new_with_filter_set(fs);
    let req = Request::new(url, src, ty, "GET").unwrap();
    let res = engine.check_network_request(&req);
    println!("rules={:?} type={} matched={}", rules, ty, matched(&res));
}
fn main() {
    let u = "https://www.pornhub.com/_xa/deep_click?h=abc&url=https%3A%2F%2Fplay.epicrespin.com";
    let s = "https://www.pornhub.com/";
    check(&["||pornhub.com/_xa/deep_click"], u, s, "document");
    check(&["||pornhub.com/_xa/deep_click$document"], u, s, "document");
    check(&["||pornhub.com/_xa/deep_click"], u, s, "xhr");
    check(&["||epicrespin.com^"], "https://play.epicrespin.com/x/index.html", s, "document");
    check(&["||epicrespin.com^$document"], "https://play.epicrespin.com/x/index.html", s, "document");
}

/// 0.13 dropped `BlockerResult::matched`; upstream's definition was
/// `exception.is_none() && (filter.is_some() || matched_rule)`, and `filter`
/// now folds in the matched_rule fallback.
fn matched(r: &adblock::blocker::BlockerResult) -> bool {
    r.exception.is_none() && r.filter.is_some()
}
