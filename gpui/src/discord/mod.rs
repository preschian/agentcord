//! Discord Rich Presence over `\\.\pipe\discord-ipc-{0..9}`.
//! Wire: `[opcode: u32 LE][length: u32 LE][json]`.

use crate::session::Activity;
use serde_json::{json, Value};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const HANDSHAKE: u32 = 0;
const FRAME: u32 = 1;
const CLOSE: u32 = 2;
const PING: u32 = 3;
const PONG: u32 = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnState {
    Disconnected,
    Connecting,
    Connected,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub state: ConnState,
    pub ready: bool,
    pub last_error: Option<String>,
}

struct Inner {
    should_run: bool,
    ready: bool,
    state: ConnState,
    client_id: String,
    activity: Option<Value>,
    dirty: bool,
    last_error: Option<String>,
    nonce: u32,
}

pub struct Client {
    inner: Arc<Mutex<Inner>>,
    write_lock: Arc<Mutex<()>>,
    thread: Mutex<Option<JoinHandle<()>>>,
    pid: u32,
}

impl Client {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                should_run: false,
                ready: false,
                state: ConnState::Disconnected,
                client_id: String::new(),
                activity: None,
                dirty: false,
                last_error: None,
                nonce: 1,
            })),
            write_lock: Arc::new(Mutex::new(())),
            thread: Mutex::new(None),
            pid: std::process::id(),
        }
    }

    pub fn connect(&self, client_id: &str) {
        {
            let g = self.inner.lock().unwrap();
            if g.should_run && g.client_id == client_id {
                return;
            }
        }
        self.disconnect();
        {
            let mut g = self.inner.lock().unwrap();
            g.client_id = client_id.to_string();
            g.should_run = true;
            g.state = ConnState::Connecting;
            g.last_error = None;
        }
        let inner = self.inner.clone();
        let write_lock = self.write_lock.clone();
        let pid = self.pid;
        let handle = thread::spawn(move || worker(inner, write_lock, pid));
        *self.thread.lock().unwrap() = Some(handle);
    }

    pub fn disconnect(&self) {
        {
            let mut g = self.inner.lock().unwrap();
            g.should_run = false;
            g.activity = None;
            g.dirty = true;
        }
        if let Some(t) = self.thread.lock().unwrap().take() {
            let _ = t.join();
        }
        let mut g = self.inner.lock().unwrap();
        g.state = ConnState::Disconnected;
        g.ready = false;
    }

    pub fn set_activity(&self, activity: Option<&Activity>) {
        let mut g = self.inner.lock().unwrap();
        let next = activity.map(activity_json);
        if g.activity == next {
            return;
        }
        g.activity = next;
        g.dirty = true;
    }

    pub fn snapshot(&self) -> Snapshot {
        let g = self.inner.lock().unwrap();
        Snapshot {
            state: g.state,
            ready: g.ready,
            last_error: g.last_error.clone(),
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.disconnect();
    }
}

fn activity_json(act: &Activity) -> Value {
    let mut obj = json!({
        "type": act.activity_type,
        "name": act.name,
        "assets": {
            "large_image": act.large_image,
            "large_text": "agentcord",
        },
        "buttons": [{
            "label": "AgentCord on GitHub",
            "url": "https://github.com/preschian/agentcord",
        }],
    });
    if let Some(details) = &act.details {
        obj["details"] = json!(details);
    }
    if let Some(state) = &act.state {
        obj["state"] = json!(state);
    }
    if act.start_ms > 0 {
        obj["timestamps"] = json!({ "start": act.start_ms });
    }
    obj
}

fn worker(inner: Arc<Mutex<Inner>>, write_lock: Arc<Mutex<()>>, pid: u32) {
    let mut attempt: u32 = 0;
    loop {
        if !inner.lock().unwrap().should_run {
            break;
        }
        inner.lock().unwrap().state = ConnState::Connecting;
        let Some(mut pipe) = open_first_pipe() else {
            inner.lock().unwrap().state = ConnState::Disconnected;
            attempt += 1;
            if !backoff(&inner, attempt) {
                break;
            }
            continue;
        };
        {
            let mut g = inner.lock().unwrap();
            g.ready = false;
        }
        let client_id = inner.lock().unwrap().client_id.clone();
        let handshake = json!({ "v": 1, "client_id": client_id }).to_string();
        if write_frame(&mut pipe, &write_lock, HANDSHAKE, handshake.as_bytes()).is_err() {
            attempt += 1;
            if !backoff(&inner, attempt) {
                break;
            }
            continue;
        }
        inner.lock().unwrap().state = ConnState::Connected;
        attempt = 0;
        read_loop(&inner, &write_lock, &mut pipe, pid);
        if !inner.lock().unwrap().should_run {
            break;
        }
        inner.lock().unwrap().state = ConnState::Disconnected;
        attempt += 1;
        if !backoff(&inner, attempt) {
            break;
        }
    }
    let mut g = inner.lock().unwrap();
    g.ready = false;
    g.state = ConnState::Disconnected;
}

fn read_loop(inner: &Arc<Mutex<Inner>>, write_lock: &Arc<Mutex<()>>, pipe: &mut File, pid: u32) {
    loop {
        let (running, dirty, activity, ready) = {
            let mut g = inner.lock().unwrap();
            let dirty = g.dirty;
            if dirty {
                g.dirty = false;
            }
            (g.should_run, dirty, g.activity.clone(), g.ready)
        };
        if !running {
            if ready {
                let _ = send_activity(inner, write_lock, pipe, pid, None);
            }
            return;
        }
        if dirty && ready {
            if send_activity(inner, write_lock, pipe, pid, activity.as_ref()).is_err() {
                inner.lock().unwrap().last_error = Some("SET_ACTIVITY write failed".into());
                return;
            }
        }
        let avail = match peek_avail(pipe) {
            Some(n) => n,
            None => return,
        };
        if avail < 8 {
            thread::sleep(Duration::from_millis(50));
            continue;
        }
        let Ok((opcode, payload)) = read_frame(pipe) else {
            return;
        };
        match opcode {
            FRAME => handle_frame(inner, write_lock, pipe, pid, &payload),
            PING => {
                if write_frame(pipe, write_lock, PONG, &payload).is_err() {
                    return;
                }
            }
            CLOSE => return,
            _ => {}
        }
    }
}

fn handle_frame(
    inner: &Arc<Mutex<Inner>>,
    write_lock: &Arc<Mutex<()>>,
    pipe: &mut File,
    pid: u32,
    payload: &[u8],
) {
    let Ok(v) = serde_json::from_slice::<Value>(payload) else {
        return;
    };
    let evt = v.get("evt").and_then(|e| e.as_str()).unwrap_or("");
    if evt == "READY" {
        let activity = {
            let mut g = inner.lock().unwrap();
            g.ready = true;
            g.last_error = None;
            g.dirty = false;
            g.activity.clone()
        };
        if let Some(act) = activity {
            let _ = send_activity(inner, write_lock, pipe, pid, Some(&act));
        }
    } else if evt == "ERROR" {
        inner.lock().unwrap().last_error = Some("Discord reported an ERROR event".into());
    }
}

fn send_activity(
    inner: &Arc<Mutex<Inner>>,
    write_lock: &Arc<Mutex<()>>,
    pipe: &mut File,
    pid: u32,
    activity: Option<&Value>,
) -> std::io::Result<()> {
    let nonce = {
        let mut g = inner.lock().unwrap();
        let n = g.nonce;
        g.nonce = g.nonce.wrapping_add(1);
        n
    };
    let cmd = json!({
        "cmd": "SET_ACTIVITY",
        "nonce": nonce.to_string(),
        "args": {
            "pid": pid,
            "activity": activity,
        }
    });
    write_frame(pipe, write_lock, FRAME, cmd.to_string().as_bytes())
}

fn write_frame(
    pipe: &mut File,
    write_lock: &Arc<Mutex<()>>,
    opcode: u32,
    payload: &[u8],
) -> std::io::Result<()> {
    let _g = write_lock.lock().unwrap();
    let mut header = [0u8; 8];
    header[0..4].copy_from_slice(&opcode.to_le_bytes());
    header[4..8].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    pipe.write_all(&header)?;
    if !payload.is_empty() {
        pipe.write_all(payload)?;
    }
    pipe.flush()
}

fn read_frame(pipe: &mut File) -> std::io::Result<(u32, Vec<u8>)> {
    let mut header = [0u8; 8];
    pipe.read_exact(&mut header)?;
    let opcode = u32::from_le_bytes(header[0..4].try_into().unwrap());
    let length = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    if length > 65_536 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut payload = vec![0u8; length];
    if length > 0 {
        pipe.read_exact(&mut payload)?;
    }
    Ok((opcode, payload))
}

fn backoff(inner: &Arc<Mutex<Inner>>, attempt: u32) -> bool {
    let secs = 2u64.pow(attempt.min(5)).min(30);
    let mut waited = 0u64;
    while waited < secs * 1000 {
        if !inner.lock().unwrap().should_run {
            return false;
        }
        thread::sleep(Duration::from_millis(100));
        waited += 100;
    }
    true
}

fn open_first_pipe() -> Option<File> {
    for i in 0..=9 {
        let path = format!(r"\\.\pipe\discord-ipc-{i}");
        let mut opts = OpenOptions::new();
        opts.read(true).write(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            opts.share_mode(0);
        }
        if let Ok(file) = opts.open(&path) {
            return Some(file);
        }
    }
    None
}

#[cfg(windows)]
fn peek_avail(pipe: &File) -> Option<u32> {
    use std::os::windows::io::AsRawHandle;
    extern "system" {
        fn PeekNamedPipe(
            handle: *mut core::ffi::c_void,
            buf: *mut u8,
            size: u32,
            read: *mut u32,
            avail: *mut u32,
            left: *mut u32,
        ) -> i32;
    }
    let mut avail = 0u32;
    let ok = unsafe {
        PeekNamedPipe(
            pipe.as_raw_handle() as *mut core::ffi::c_void,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut avail,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        None
    } else {
        Some(avail)
    }
}

#[cfg(not(windows))]
fn peek_avail(_pipe: &File) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Activity, AgentKind};

    #[test]
    fn activity_json_includes_name() {
        let act = Activity {
            name: "Grok".into(),
            details: Some("Grok 4.5".into()),
            state: Some("Working on: agentcord".into()),
            start_ms: 1_700_000_000_000,
            large_image: AgentKind::Grok.large_image(),
            activity_type: 3,
        };
        let v = activity_json(&act);
        assert_eq!(v["name"], "Grok");
        assert_eq!(v["type"], 3);
        assert_eq!(v["details"], "Grok 4.5");
        assert_eq!(v["assets"]["large_image"], "logo-grok");
        assert_eq!(v["timestamps"]["start"], 1_700_000_000_000_i64);
    }
}
