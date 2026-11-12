// sitetest DAT SOURCE_URL  < lines "TYPE URL": which requests of a page the engine blocks.
use adblock::{request::Request, Engine};
use std::io::BufRead;
fn main() {
    let mut args = std::env::args().skip(1);
    let dat = args.next().expect("DAT");
    let source = args.next().expect("SOURCE_URL");
    let mut engine = Engine::default();
    engine.deserialize(&std::fs::read(&dat).unwrap()).unwrap();
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let mut parts = line.splitn(2, ' ');
        let (ty, url) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        if url.is_empty() { continue; }
        let Ok(req) = Request::new(url, &source, ty, "GET") else { println!("BADURL {url}"); continue; };
        let r = engine.check_network_request(&req);
        let blocked = r.exception.is_none() && r.filter.is_some();
        println!("{} {} {} filter={:?} exception={:?} redirect={:?}", if blocked { "BLOCK" } else { "ok   " }, ty, url, r.filter, r.exception, r.redirect.as_ref().map(|s| s.len()));
    }
}
