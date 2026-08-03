use adblock::{Engine, FilterSet, lists::ParseOptions, request::Request};
fn check(rules: &[&str], url: &str, src: &str, ty: &str) {
    let mut fs = FilterSet::new(false);
    fs.add_filters(&rules.iter().map(|s| s.to_string()).collect::<Vec<_>>(), ParseOptions::default());
    let engine = Engine::from_filter_set(fs, true);
    let req = Request::new(url, src, ty).unwrap();
    let res = engine.check_network_request(&req);
    println!("rules={:?} type={} matched={}", rules, ty, res.matched);
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
