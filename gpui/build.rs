fn main() {
    println!("cargo:rerun-if-changed=assets/agentcord.ico");
    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/agentcord.ico");
        res.compile().expect("embed agentcord.ico");
    }
}
