import Foundation

func v(_ tag: String) -> AppReleaseVersion { AppReleaseVersion(tag: tag)! }
func row(_ tag: String, ext: String = ".dmg", draft: Bool = false, page: String? = nil) -> [String: Any] {
    ["tag_name":tag,"html_url":page ?? "https://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/"+tag,
     "draft":draft,"prerelease":true,"assets":[["name":"PJDVM39-"+tag+ext,"state":"uploaded"]]]
}
func payload(_ rows: [[String:Any]]) -> Data { try! JSONSerialization.data(withJSONObject:rows) }
precondition(v("v0.1.5b10") > v("v0.1.5b9") && v("v0.2.0b1") > v("v0.1.5b999"))
for bad in ["v0.1.5b", "garbage", "0.1", "v0.1.5b999999999999999999999999", "v0.1.5b2\n"] { precondition(AppReleaseVersion(tag:bad)==nil) }
let newest = try ReleaseUpdatePolicy.newest(payload([row("v0.1.5b9"),row("v0.1.5b24"),row("v0.1.5b25",draft:true),row("v0.1.5b99",ext:".ipa"),row("v9.0.0",page:"https://example.com/update")]),assetExtension:".dmg")
precondition(newest?.version==v("v0.1.5b24"))
precondition(!ReleaseUpdatePolicy.releasePage(URL(string:"http://github.com/HachiMiku39/pjdv_mega39s_ios/releases/tag/x")!))
print("PASS numeric tags, preview releases, platform assets, drafts and foreign-link rejection")

final class MockURL: URLProtocol {
    static let lock = NSLock()
    static var requests = [URLRequest]()
    static var status = 200
    static var data = payload([row("v0.1.5b24")])
    static var headers = ["ETag":"\"fixture24\""]
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock();Self.requests.append(request)
        let code=Self.status,data=Self.data,headers=Self.headers,fail=Self.fail;Self.lock.unlock()
        if fail {client?.urlProtocol(self,didFailWithError:URLError(.timedOut));return}
        let response=HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        for start in stride(from:0,to:data.count,by:32768) {client?.urlProtocol(self,didLoad:data.subdata(in:start..<min(data.count,start+32768)))}
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let suite="PJDV.ReleaseTests."+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer {defaults.removePersistentDomain(forName:suite)}
let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MockURL.self]
func client() -> ReleaseUpdateChecker {ReleaseUpdateChecker(defaults:defaults,configuration:config,current:v("0.1.5b23"),assetExtension:".dmg")}
func wait(_ predicate: () -> Bool) {
    let deadline=Date().addingTimeInterval(10)
    while !predicate(), Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    precondition(predicate(),"Asynchronous checker timed out")
}
func check(_ checker: ReleaseUpdateChecker, force: Bool=false) -> ReleaseUpdateResult {
    var result:ReleaseUpdateResult?;checker.check(force:force){result=$0};wait{result != nil};return result!
}
let checker=client()
var values=[ReleaseUpdateResult]()
checker.check{values.append($0)};checker.check{values.append($0)};wait{values.count==2}
if case .available(let r)=values[0] {precondition(r.tag=="v0.1.5b24")} else {fatalError("No update")}
precondition(MockURL.requests.count==1)
_=check(checker);precondition(MockURL.requests.count==1)
MockURL.status=304;MockURL.data=Data()
if case .available = check(client()) {} else {fatalError("304 lost cached update")}
precondition(MockURL.requests.last?.value(forHTTPHeaderField:"If-None-Match")=="\"fixture24\"")
precondition(MockURL.requests.allSatisfy{$0.value(forHTTPHeaderField:"Authorization")==nil})
print("PASS one request per launch, concurrent coalescing, ETag/304 across launches and no credentials")
MockURL.status=200;MockURL.data=payload([row("v0.1.5b22")])
if case .current = check(client()) {} else {fatalError("False downgrade prompt")}
MockURL.data=Data("invalid".utf8)
if case .unavailable = check(client()) {} else {fatalError("Bad JSON claimed latest")}
MockURL.fail=true
if case .unavailable = check(client()) {} else {fatalError("Offline claimed latest")}
MockURL.fail=false;MockURL.data=Data(repeating:65,count:ReleaseUpdatePolicy.maximumBytes+32768)
if case .unavailable = check(client()) {} else {fatalError("Oversized payload accepted")}
MockURL.status=429;MockURL.data=Data();MockURL.headers=["Retry-After":"120"]
if case .rateLimited = check(client()) {} else {fatalError("No rate backoff")}
let count=MockURL.requests.count
if case .rateLimited = check(client(),force:true) {} else {fatalError("Backoff bypassed")}
precondition(MockURL.requests.count==count)
print("PASS no downgrade, invalid JSON, timeout, bounded response and persisted rate-limit backoff")
