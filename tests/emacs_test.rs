use emaclaude::emacs::EmacsBridge;

fn bridge() -> EmacsBridge {
    EmacsBridge::new("emacsclient".to_string())
}

#[test]
fn build_eval_command() {
    let b = bridge();
    let elisp = "(message \"hello\")";
    let cmd = b.build_eval(elisp);
    // program
    assert_eq!(cmd.get_program(), "emacsclient");
    // args
    let args: Vec<&std::ffi::OsStr> = cmd.get_args().collect();
    assert_eq!(args.len(), 2);
    assert_eq!(args[0], "--eval");
    assert_eq!(args[1], elisp);
}

#[test]
fn send_to_buffer_elisp_generation() {
    let b = bridge();
    // plain text
    assert_eq!(
        b.send_to_buffer_elisp("*claude*", "hello world"),
        r#"(emaclaude--send-to-buffer "*claude*" "hello world")"#
    );
    // text with backslash and quote that need escaping
    assert_eq!(
        b.send_to_buffer_elisp("*buf*", r#"say "hi" and c:\path"#),
        r#"(emaclaude--send-to-buffer "*buf*" "say \"hi\" and c:\\path")"#
    );
}

#[test]
fn spawn_buffer_elisp_generation() {
    let b = bridge();
    assert_eq!(
        b.spawn_buffer_elisp("*shell*", "cargo test"),
        r#"(emaclaude--spawn-buffer "*shell*" "cargo test")"#
    );
}

#[test]
fn notify_elisp_escapes_quotes() {
    let b = bridge();
    assert_eq!(
        b.notify_elisp(r#"done: "task""#),
        r#"(emaclaude--notify "done: \"task\"")"#
    );
}
