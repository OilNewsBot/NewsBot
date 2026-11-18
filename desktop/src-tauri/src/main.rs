//! NewsDrop desktop window.
//!
//! Starts the existing NewsDrop service (`jac run` in the repository root),
//! waits for it to listen, and shows its page in a native window. Quitting the
//! window stops the service it started. If a service is already listening on
//! the configured port, the window reuses it and leaves it running on quit.
//! Links to posts (x.com, t.me, ...) open in the default browser.
//!
//! Remote mode, for demos: with `NEWSBOT_URL` set (at build time, or in the
//! environment at run time), the window is a thin client for that server. It
//! starts and stops nothing locally and needs no NewsDrop folder.
//!
//! Jac has no Windows build, so on Windows the service runs in Ubuntu on WSL
//! (docs/getting-started.md) and the window connects to it over localhost.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::{self, File};
use std::io::Read;
use std::net::{Ipv6Addr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use tauri::ipc::CapabilityBuilder;
use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::{Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// The first start compiles the web page (`jac build web`), which is slow.
const START_TIMEOUT: Duration = Duration::from_secs(300);
/// uvicorn caps graceful shutdown at 5 s (app.jac); allow a little more.
const STOP_TIMEOUT: Duration = Duration::from_secs(8);

/// The service this app started, if any; stopped when the app exits.
struct Service(Mutex<Option<Child>>);

/// Remote server for a thin-client app: `NEWSBOT_URL` from the environment,
/// else the value it had when the app was built. None means local mode.
fn remote_setting() -> Option<String> {
    std::env::var("NEWSBOT_URL")
        .ok()
        .or_else(|| option_env!("NEWSBOT_URL").map(String::from))
        .filter(|value| !value.trim().is_empty())
}

fn remote_url(raw: &str) -> Result<Url, &'static str> {
    let invalid = "Set NEWSBOT_URL to the full server address, including http:// or https://.";
    let url = Url::parse(raw.trim()).map_err(|_| invalid)?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(invalid);
    }
    url.join("/").map_err(|_| invalid)
}

/// Repository root: `NEWSBOT_ROOT`, else the checkout this app was built from.
fn repo_root() -> PathBuf {
    let root = std::env::var_os("NEWSBOT_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));
    let root = root.canonicalize().unwrap_or(root);
    // Windows canonical paths start with \\?\, which wslpath does not accept.
    #[cfg(windows)]
    let root = {
        let text = root.to_string_lossy();
        PathBuf::from(match text.strip_prefix(r"\\?\UNC\") {
            Some(unc) => format!(r"\\{unc}"),
            None => text.trim_start_matches(r"\\?\").to_string(),
        })
    };
    root
}

/// `server.host` and `server.port` from config.yaml (defaults 127.0.0.1:8000).
/// A small line scan is enough for this flat two-level section.
fn server_address(root: &Path) -> (String, u16) {
    let (mut host, mut port) = ("127.0.0.1".to_string(), 8000);
    let text = fs::read_to_string(root.join("config.yaml")).unwrap_or_default();
    let mut in_server = false;
    for line in text.lines() {
        if !line.starts_with(' ') && !line.trim().is_empty() && !line.starts_with('#') {
            in_server = line.trim_end() == "server:";
            continue;
        }
        if !in_server {
            continue;
        }
        let value = |key: &str| {
            line.trim()
                .strip_prefix(key)
                .map(|v| v.split('#').next().unwrap_or("").trim().trim_matches('"').to_string())
        };
        if let Some(v) = value("host:") {
            host = v;
        } else if let Some(v) = value("port:") {
            port = v.parse().unwrap_or(port);
        }
    }
    match host.as_str() {
        "0.0.0.0" => host = "127.0.0.1".to_string(),
        "::" | "[::]" => host = "::1".to_string(),
        _ => {}
    }
    (host, port)
}

fn local_url(host: &str, port: u16) -> Result<Url, &'static str> {
    let invalid = "Check server.host and server.port in config.yaml.";
    let mut url = Url::parse("http://localhost/").expect("constant HTTP URL");
    if let Ok(ip) = host.parse::<Ipv6Addr>() {
        url.set_ip_host(ip.into()).map_err(|_| invalid)?;
    } else {
        url.set_host(Some(host)).map_err(|_| invalid)?;
    }
    url.set_port(Some(port)).map_err(|_| invalid)?;
    Ok(url)
}

fn listening(server: &Url, timeout: Duration) -> bool {
    server.socket_addrs(|| None).is_ok_and(|addresses| {
        addresses.into_iter().any(|address| TcpStream::connect_timeout(&address, timeout).is_ok())
    })
}

// Existing NewsDrop releases expose the FastAPI schema without requiring a
// session. Verify the application before reusing another process's listener.
fn is_newsbot(server: &Url) -> bool {
    let Ok(schema) = server.join("/openapi.json") else {
        return false;
    };
    let Ok(client) = reqwest::blocking::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(4))
        .build()
    else {
        return false;
    };
    let Ok(response) = client.get(schema).send().and_then(|r| r.error_for_status()) else {
        return false;
    };
    let Ok(doc) = serde_json::from_reader::<_, serde_json::Value>(response.take(2 * 1024 * 1024))
    else {
        return false;
    };
    matches!(doc["info"]["title"].as_str(), Some("NewsDrop" | "newsstream"))
        && doc["paths"]["/feed"]["get"].is_object()
        && doc["paths"]["/notifications"]["get"].is_object()
}

/// macOS apps opened from Finder get a minimal PATH, without Homebrew or
/// ~/.local/bin, so find jac (and node/npm for its web build) explicitly.
#[cfg(unix)]
fn tool_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let current = std::env::var("PATH").unwrap_or_default();
    format!("{home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:{current}")
}

#[cfg(unix)]
fn jac_executable() -> PathBuf {
    if let Some(jac) = std::env::var_os("JAC_EXECUTABLE") {
        return PathBuf::from(jac);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    [
        format!("{home}/.local/bin/jac"),
        "/opt/homebrew/bin/jac".to_string(),
        "/usr/local/bin/jac".to_string(),
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|p| p.is_file())
    .unwrap_or_else(|| PathBuf::from("jac"))
}

/// Start `jac run` in its own process group so stopping it also stops
/// anything it spawned. Output goes to data/desktop-server.log (ignored by Git).
#[cfg(unix)]
fn start_service(root: &Path, log_path: &Path) -> std::io::Result<Child> {
    use std::os::unix::process::CommandExt;
    fs::create_dir_all(log_path.parent().unwrap())?;
    let log = File::create(log_path)?;
    let jac = jac_executable();
    Command::new(&jac)
        .arg("run")
        .current_dir(root)
        .env("PATH", tool_path())
        .env("JAC_EXECUTABLE", &jac)
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .process_group(0)
        .spawn()
}

#[cfg(unix)]
fn signal_group(child: &Child, _root: &Path, signal: &str) {
    let _ = Command::new("kill")
        .args([signal, &format!("-{}", child.id())])
        .status();
}

/// The Linux process group of the service in WSL, written by its start script.
#[cfg(windows)]
const PID_FILE: &str = "data/desktop-server.pid";

/// `wsl -d <distro>` without a console window (this app has none to share).
/// The distro name matches scripts/bootstrap.py.
#[cfg(windows)]
fn wsl() -> Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let distro = std::env::var("NEWSBOT_WSL_DISTRO").unwrap_or_else(|_| "Ubuntu".to_string());
    let mut command = Command::new("wsl");
    command.args(["-d", &distro]).creation_flags(CREATE_NO_WINDOW);
    command
}

/// Start `jac run` in WSL as the leader of a new Linux session, recording its
/// process group so stopping it also stops anything it spawned. A login shell
/// picks up ~/.local/bin, where scripts/bootstrap.py installs jac.
#[cfg(windows)]
fn start_service(root: &Path, log_path: &Path) -> std::io::Result<Child> {
    fs::create_dir_all(log_path.parent().unwrap())?;
    let _ = fs::remove_file(root.join(PID_FILE));
    let output = wsl().args(["--exec", "wslpath", "-a"]).arg(root).output()?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).replace('\0', "");
        return Err(std::io::Error::other(format!(
            "WSL could not open {}: {}\nInstall Ubuntu in WSL (see docs/getting-started.md) \
             or set NEWSBOT_WSL_DISTRO to its name.",
            root.display(),
            detail.trim()
        )));
    }
    let linux_root = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let script = format!(
        "echo $$ > {PID_FILE}; export PATH=\"$HOME/.local/bin:$PATH\"; \
         export JAC_EXECUTABLE=\"$(command -v jac)\"; exec jac run"
    );
    let log = File::create(log_path)?;
    wsl()
        .args(["--cd", &linux_root, "--exec", "setsid", "--wait", "bash", "-lc", &script])
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()
}

#[cfg(windows)]
fn signal_group(_child: &Child, root: &Path, signal: &str) {
    let group = fs::read_to_string(root.join(PID_FILE)).unwrap_or_default();
    if let Ok(group) = group.trim().parse::<u32>() {
        let _ = wsl()
            .args(["--exec", "kill", signal, "--", &format!("-{group}")])
            .status();
    }
}

fn stop_service(mut child: Child, root: &Path) {
    signal_group(&child, root, "-TERM");
    let deadline = Instant::now() + STOP_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    signal_group(&child, root, "-KILL");
    let _ = child.kill();
    let _ = child.wait();
}

fn last_lines(path: &Path, n: usize) -> String {
    let text = fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// Quote a string for use inside a JavaScript call.
fn js_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            '<' => out.push_str("\\u003c"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn show_error(window: &WebviewWindow, title: &str, detail: &str) {
    let _ = window.eval(format!(
        "window.showError({}, {})",
        js_string(title),
        js_string(detail)
    ));
}

/// Pages that stay in the window: the bundled loading page and the service
/// (the remote server in remote mode, otherwise the local port).
fn is_local(url: &Url, server: Option<&Url>, remote: bool) -> bool {
    match url.scheme() {
        "tauri" | "about" | "data" => true,
        "http" | "https" if url.host_str() == Some("tauri.localhost") => true,
        "http" | "https" => server.is_some_and(|target| {
            url.origin() == target.origin()
                || (!remote && url.scheme() == "http"
                    && matches!(url.host_str(), Some("127.0.0.1" | "localhost"))
                    && url.port_or_known_default() == target.port_or_known_default())
        }),
        _ => false,
    }
}

#[cfg(target_os = "macos")]
fn open_in_browser(url: &Url) {
    let _ = Command::new("open").arg(url.as_str()).spawn();
}

#[cfg(all(unix, not(target_os = "macos")))]
fn open_in_browser(url: &Url) {
    let _ = Command::new("xdg-open").arg(url.as_str()).spawn();
}

#[cfg(windows)]
fn open_in_browser(url: &Url) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = Command::new("explorer")
        .arg(url.as_str())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

/// Wait for the service, then point the window at it (runs on its own thread).
fn connect(app: tauri::AppHandle, root: PathBuf, page: Url) {
    let window = app.get_webview_window("main").expect("main window");
    let timeout = Duration::from_millis(300);
    if !listening(&page, timeout) {
        if !root.join("jac.toml").is_file() {
            show_error(
                &window,
                "NewsDrop folder not found",
                &format!(
                    "No jac.toml in {}.\nSet NEWSBOT_ROOT to the NewsDrop folder.",
                    root.display()
                ),
            );
            return;
        }
        let log_path = root.join("data/desktop-server.log");
        match start_service(&root, &log_path) {
            Ok(child) => *app.state::<Service>().0.lock().unwrap() = Some(child),
            Err(e) => {
                show_error(
                    &window,
                    "Could not run jac",
                    &format!(
                        "{e}\nRun python3 scripts/bootstrap.py in {} \
                         (Windows: python, which installs jac in WSL).",
                        root.display()
                    ),
                );
                return;
            }
        }
        let deadline = Instant::now() + START_TIMEOUT;
        while !listening(&page, timeout) {
            let exited = app
                .state::<Service>()
                .0
                .lock()
                .unwrap()
                .as_mut()
                .and_then(|c| c.try_wait().ok().flatten());
            if let Some(status) = exited {
                show_error(
                    &window,
                    &format!("NewsDrop stopped while starting ({status})"),
                    &format!("{}\n\nFull log: {}", last_lines(&log_path, 25), log_path.display()),
                );
                return;
            }
            if Instant::now() > deadline {
                show_error(
                    &window,
                    "NewsDrop is taking too long to start",
                    &format!("{}\n\nFull log: {}", last_lines(&log_path, 25), log_path.display()),
                );
                return;
            }
            thread::sleep(Duration::from_millis(500));
        }
    }
    if !is_newsbot(&page) {
        show_error(
            &window,
            "The configured port did not return NewsDrop",
            &format!("Check the service at {page} or change server.port in config.yaml."),
        );
        return;
    }
    let _ = window.navigate(page);
}

/// Remote mode: wait briefly for the server to answer, then show it.
fn connect_remote(app: tauri::AppHandle, server: Url) {
    let window = app.get_webview_window("main").expect("main window");
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut reported = false;
    loop {
        if listening(&server, Duration::from_secs(3)) {
            let _ = window.navigate(server);
            return;
        }
        if !reported && Instant::now() > deadline {
            show_error(
                &window,
                "Cannot reach the NewsDrop server",
                &format!("{server}\nCheck your connection. NewsDrop will retry automatically."),
            );
            reported = true;
        }
        thread::sleep(Duration::from_secs(if reported { 3 } else { 1 }));
    }
}

/// Lets the service's pages (a remote origin to Tauri) send notifications and
/// nothing else. Built at startup because the port comes from config.yaml, or
/// the server from NEWSBOT_URL in remote mode.
fn service_notifications(server: &Url, remote: bool) -> CapabilityBuilder {
    // Tauri uses URLPattern syntax. Literal colons in an IPv6 hostname
    // must be escaped there, independently of the actual browser URL.
    let host_pattern = server.host_str().expect("HTTP server host").replace(':', r"\:");
    let port_pattern = server.port().map(|n| format!(":{n}")).unwrap_or_default();
    let pattern = format!("{}://{host_pattern}{port_pattern}/*", server.scheme());
    let mut capability = CapabilityBuilder::new("service-notifications")
        .local(false)
        .window("main")
        .permission("notification:allow-is-permission-granted")
        .permission("notification:allow-request-permission")
        .permission("notification:allow-notify")
        .remote(pattern);
    if !remote {
        for host in ["127.0.0.1", "localhost"] {
            if server.host_str() != Some(host) {
                let port = server.port_or_known_default().expect("HTTP server port");
                capability = capability.remote(format!("http://{host}:{port}/*"));
            }
        }
    }
    capability
}

fn main() {
    let root = repo_root();
    let setting = remote_setting();
    let remote = setting.is_some();
    let target = match setting {
        Some(raw) => remote_url(&raw),
        None => {
            let (host, port) = server_address(&root);
            local_url(&host, port)
        }
    };
    let service_root = root.clone();

    let app = tauri::Builder::default()
        // Replaces the page's Notification API (which these webviews lack) with
        // native system notifications, so the existing page checkboxes work.
        .plugin(tauri_plugin_notification::init())
        .manage(Service(Mutex::new(None)))
        .setup(move |app| {
            if let Ok(server) = &target {
                app.add_capability(service_notifications(server, remote))?;
            }
            let navigation_target = target.clone();
            let started = AtomicBool::new(false);
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("NewsDrop")
                .inner_size(1280.0, 860.0)
                .min_inner_size(720.0, 480.0)
                .on_navigation(move |url| {
                    let local = is_local(url, navigation_target.as_ref().ok(), remote);
                    if !local {
                        open_in_browser(url);
                    }
                    local
                })
                .on_new_window(|url, _| {
                    open_in_browser(&url);
                    NewWindowResponse::Deny
                })
                .on_page_load(move |window, payload| {
                    // The bundled page installs showError during load. Starting
                    // after that point also makes immediate config errors visible.
                    if payload.event() != PageLoadEvent::Finished
                        || started.swap(true, Ordering::SeqCst)
                    {
                        return;
                    }
                    let handle = window.app_handle().clone();
                    match target.clone() {
                        Ok(server) if remote => {
                            thread::spawn(move || connect_remote(handle, server));
                        }
                        Ok(server) => {
                            let service_root = root.clone();
                            thread::spawn(move || connect(handle, service_root, server));
                        }
                        Err(detail) => show_error(&window, "Invalid NewsDrop server address", detail),
                    }
                })
                .build()?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building the NewsDrop window");

    // The service runs in its own process group, so a terminal's Ctrl+C does
    // not reach it; exit through Tauri instead so RunEvent::Exit stops it.
    let handle = app.handle().clone();
    ctrlc::set_handler(move || handle.exit(0)).expect("signal handler");

    app.run(move |app, event| {
        if let RunEvent::Exit = event {
            if let Some(child) = app.state::<Service>().0.lock().unwrap().take() {
                stop_service(child, &service_root);
            }
        }
    });
}
