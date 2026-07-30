use adblock::{Engine, request::Request};
fn main() {
    let mut args = std::env::args().skip(1);
    let dat = args.next().unwrap(); let url = args.next().unwrap();
    let data = std::fs::read(&dat).unwrap();
    let mut engine = Engine::default();
    engine.deserialize(&data).unwrap();
    for ty in ["media", "xhr", "other", "document"] {
        let req = Request::new(&url, "https://www.pornhub.com/view_video.php", ty).unwrap();
        let r = engine.check_network_request(&req);
        println!("type={} matched={} important={} exception={:?} filter={:?}", ty, r.matched, r.important, r.exception, r.filter);
    }
}
