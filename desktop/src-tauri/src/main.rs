//! NewsBot desktop window.
//!
//! Starts the existing newsstream service (`jac run` in the repository root),
//! waits for it to listen, and shows its page in a native window. Quitting the
//! window stops the service it started. If a service is already listening on
//! the configured port, the window reuses it and leaves it running on quit.
//! Links to posts (x.com, t.me, ...) open in the default browser.
//!
//! Jac has no Windows build, so on Windows the service runs in Ubuntu on WSL
//! (docs/getting-started.md) and the window connects to it over localhost.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs::{self, File};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use tauri::webview::NewWindowResponse;
use tauri::{Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// The first start compiles the web page (`jac build web`), which is slow.
const START_TIMEOUT: Duration = Duration::from_secs(300);
/// uvicorn caps graceful shutdown at 5 s (app.jac); allow a little more.
const STOP_TIMEOUT: Duration = Duration::from_secs(8);

/// The service this app started, if any; stopped when the app exits.
struct Service(Mutex<Option<Child>>);

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
    // 0.0.0.0 is a listen address, not one to connect to.
    if host == "0.0.0.0" {
        host = "127.0.0.1".to_string();
    }
    (host, port)
}

fn listening(addr: &SocketAddr) -> bool {
    TcpStream::connect_timeout(addr, Duration::from_millis(300)).is_ok()
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

/// Pages that stay in the window: the bundled loading page and the service.
fn is_local(url: &Url, port: u16) -> bool {
    match url.scheme() {
        "tauri" | "about" | "data" => true,
        "http" | "https" => match url.host_str() {
            Some("tauri.localhost") => true,
            Some("127.0.0.1" | "localhost") => url.port_or_known_default() == Some(port),
            _ => false,
        },
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
fn connect(app: tauri::AppHandle, root: PathBuf, host: String, port: u16) {
    let window = app.get_webview_window("main").expect("main window");
    let page = Url::parse(&format!("http://{host}:{port}/")).expect("service URL");
    let Some(addr) = (host.as_str(), port).to_socket_addrs().ok().and_then(|mut a| a.next())
    else {
        show_error(&window, "Bad server address", &format!("{host}:{port} in config.yaml"));
        return;
    };

    if !listening(&addr) {
        if !root.join("jac.toml").is_file() {
            show_error(
                &window,
                "NewsBot folder not found",
                &format!(
                    "No jac.toml in {}.\nSet NEWSBOT_ROOT to the NewsBot folder.",
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
        while !listening(&addr) {
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
                    &format!("NewsBot stopped while starting ({status})"),
                    &format!("{}\n\nFull log: {}", last_lines(&log_path, 25), log_path.display()),
                );
                return;
            }
            if Instant::now() > deadline {
                show_error(
                    &window,
                    "NewsBot is taking too long to start",
                    &format!("{}\n\nFull log: {}", last_lines(&log_path, 25), log_path.display()),
                );
                return;
            }
            thread::sleep(Duration::from_millis(500));
        }
    }
    let _ = window.navigate(page);
}

fn main() {
    let root = repo_root();
    let (host, port) = server_address(&root);
    let service_root = root.clone();

    let app = tauri::Builder::default()
        .manage(Service(Mutex::new(None)))
        .setup(move |app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("NewsBot")
                .inner_size(1280.0, 860.0)
                .min_inner_size(720.0, 480.0)
                .on_navigation(move |url| {
                    let local = is_local(url, port);
                    if !local {
                        open_in_browser(url);
                    }
                    local
                })
                .on_new_window(|url, _| {
                    open_in_browser(&url);
                    NewWindowResponse::Deny
                })
                .build()?;
            let handle = app.handle().clone();
            thread::spawn(move || connect(handle, root, host, port));
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building the NewsBot window");

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
