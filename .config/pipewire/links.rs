#!/usr/bin/env rust-script

//! PipeWire Links Manager - Rust implementation
//! Monitors PipeWire node events and maintains audio connections

use std::collections::HashSet;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct Port {
    device: String,
    port_type: String, // capture, playback, monitor
    channel: String,   // FL, FR, 1, 2, 3, 4, etc.
}

impl Port {
    fn from_alias(alias: &str) -> Option<Self> {
        let parts: Vec<&str> = alias.split(':').collect();
        if parts.len() != 2 {
            return None;
        }

        let device = parts[0].to_string();
        let port_parts: Vec<&str> = parts[1].split('_').collect();
        if port_parts.len() != 2 {
            return None;
        }

        let port_type = port_parts[0].to_string();
        let channel = port_parts[1].to_string();

        Some(Port {
            device,
            port_type,
            channel,
        })
    }

    fn to_alias(&self) -> String {
        format!("{}:{}_{}", self.device, self.port_type, self.channel)
    }
}

struct PipeWireManager {
    existing_ports: Arc<Mutex<HashSet<String>>>,
}

impl PipeWireManager {
    fn new() -> Self {
        PipeWireManager {
            existing_ports: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    fn get_komplete_input_node(&self) -> Option<String> {
        let output = Command::new("pw-cli")
            .args(&["list-objects", "Node"])
            .output()
            .unwrap_or_else(|_| {
                eprintln!("Failed to run pw-cli list-objects Node");
                std::process::exit(1);
            });

        let stdout = String::from_utf8_lossy(&output.stdout);

        for line in stdout.lines() {
            if line.contains("node.name")
                && line.contains("Komplete")
                && line.contains("alsa_input")
            {
                if let Some(start) = line.find("node.name = \"") {
                    let start = start + 13;
                    if let Some(end) = line[start..].find("\"") {
                        return Some(line[start..start + end].to_string());
                    }
                }
            }
        }

        None
    }

    fn get_hardware_outputs(&self) -> Vec<String> {
        let output = Command::new("pw-cli")
            .args(&["list-objects", "Node"])
            .output()
            .unwrap_or_else(|_| {
                eprintln!("Failed to run pw-cli list-objects Node");
                std::process::exit(1);
            });

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut outputs = Vec::new();

        for line in stdout.lines() {
            // Only route to Komplete Audio output, not HDMI/IEC958/other outputs
            if line.contains("node.name")
                && line.contains("alsa_output")
                && line.contains("Komplete")
            {
                if let Some(start) = line.find("node.name = \"") {
                    let start = start + 13;
                    if let Some(end) = line[start..].find("\"") {
                        let node_name = &line[start..start + end];
                        outputs.push(node_name.to_string());
                    }
                }
            }
        }

        outputs
    }

    fn get_all_ports(&self) -> HashSet<String> {
        let output = Command::new("pw-cli")
            .args(&["list-objects", "Port"])
            .output()
            .unwrap_or_else(|_| {
                eprintln!("Failed to run pw-cli list-objects Port");
                std::process::exit(1);
            });

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut ports = HashSet::new();

        for line in stdout.lines() {
            if line.contains("port.alias = \"") {
                if let Some(start) = line.find("port.alias = \"") {
                    let start = start + 14;
                    if let Some(end) = line[start..].find("\"") {
                        let port_alias = &line[start..start + end];
                        ports.insert(port_alias.to_string());
                    }
                }
            }
        }

        ports
    }

    fn get_existing_links(&self) -> HashSet<(String, String)> {
        let output = Command::new("pw-link")
            .arg("-l")
            .output()
            .unwrap_or_else(|_| {
                eprintln!("Failed to run pw-link -l");
                std::process::exit(1);
            });

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut links = HashSet::new();

        for line in stdout.lines() {
            if line.contains(" -> ") {
                let parts: Vec<&str> = line.split(" -> ").collect();
                if parts.len() == 2 {
                    let source = parts[0].trim();
                    let sink = parts[1].trim();
                    links.insert((source.to_string(), sink.to_string()));
                }
            }
        }

        links
    }

    fn link_exists(&self, source: &str, sink: &str) -> bool {
        let links = self.get_existing_links();
        links.contains(&(source.to_string(), sink.to_string()))
    }

    fn create_link(&self, source: &str, sink: &str) -> bool {
        if self.link_exists(source, sink) {
            println!("Link already exists: {} -> {}", source, sink);
            return true;
        }

        for attempt in 1..=10 {
            let output = Command::new("pw-link").args(&[source, sink]).output();

            match output {
                Ok(result) if result.status.success() => {
                    println!("Created link: {} -> {}", source, sink);
                    return true;
                }
                Ok(output) => {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    if stderr.contains("File exists") {
                        println!("Link already exists: {} -> {}", source, sink);
                        return true;
                    } else if stderr.contains("No such file or directory") {
                        eprintln!(
                            "Ports not ready: {} -> {} (attempt {})",
                            source, sink, attempt
                        );
                    } else {
                        eprintln!(
                            "Failed to create link: {} -> {} (attempt {}): {}",
                            source, sink, attempt, stderr
                        );
                    }

                    if attempt < 10 {
                        thread::sleep(Duration::from_millis(500));
                        continue;
                    }
                    return false;
                }
                Err(e) => {
                    eprintln!("Error running pw-link: {}", e);
                    if attempt < 10 {
                        thread::sleep(Duration::from_millis(500));
                        continue;
                    }
                    return false;
                }
            }
        }

        false
    }

    fn process_connections_for_port(&self, port: &Port) {
        println!("Processing connections for port: {}", port.to_alias());

        let komplete_input_node = self.get_komplete_input_node();
        let loopmix_node = "input.loopmix";
        let repeater_node = "repeater";

        // Handle Komplete mic connections
        if port.device == "Komplete Audio 1" && port.port_type == "capture" {
            if let Some(komplete_node) = komplete_input_node {
                let source_port = format!("{}:capture_{}", komplete_node, port.channel);
                let sink_port1 = format!("{}:playback_3", loopmix_node);
                let sink_port2 = format!("{}:playback_4", loopmix_node);

                self.create_link(&source_port, &sink_port1);
                self.create_link(&source_port, &sink_port2);
            }
        }

        // Handle loopmix monitor connections (only channels 1 and 2)
        if port.device == "loopmix"
            && port.port_type == "monitor"
            && (port.channel == "1" || port.channel == "2")
        {
            let source_port = format!("{}:monitor_{}", loopmix_node, port.channel);
            let sink_port = format!(
                "{}:playback_{}",
                repeater_node,
                if port.channel == "1" { "FL" } else { "FR" }
            );

            self.create_link(&source_port, &sink_port);
        }

        // Handle repeater monitor -> hardware outputs
        if port.device == "repeater" && port.port_type == "monitor" {
            let source_port = format!("{}:monitor_{}", repeater_node, port.channel);
            let hardware_outputs = self.get_hardware_outputs();
            for output_device in hardware_outputs {
                let sink_port = format!("{}:playback_{}", output_device, port.channel);
                self.create_link(&source_port, &sink_port);
            }
        }
    }

    fn setup_all_connections(&self) {
        println!("Setting up all audio connections...");

        let current_ports = self.get_all_ports();
        let mut port_objects = Vec::new();

        for port_alias in &current_ports {
            if let Some(port) = Port::from_alias(port_alias) {
                port_objects.push(port);
            }
        }

        for port in port_objects {
            self.process_connections_for_port(&port);
        }

        println!("Connection setup complete");
    }

    fn monitor_pipe_wire_events(&self) {
        println!("Starting PipeWire event monitoring...");

        let mut child = Command::new("pactl")
            .args(&["subscribe"])
            .stdout(Stdio::piped())
            .spawn()
            .expect("Failed to start pactl subscribe");

        let stdout = child.stdout.take().expect("Failed to take stdout");
        use std::io::{BufRead, BufReader};

        let reader = BufReader::new(stdout);
        let existing_ports = self.existing_ports.clone();

        for line in reader.lines() {
            match line {
                Ok(line) => {
                    if line.contains("new") && (line.contains("sink") || line.contains("source")) {
                        println!("Device event: {}", line);

                        // Wait for ports to be ready
                        thread::sleep(Duration::from_millis(2000));

                        // Run full connection setup instead of just processing new ports
                        println!("Running full connection setup due to device event...");
                        self.setup_all_connections();
                    }
                }
                Err(e) => {
                    eprintln!("Error reading from pactl subscribe: {}", e);
                    break;
                }
            }
        }

        let _ = child.wait();
    }

    fn run(&mut self) {
        println!("PipeWire Links Manager starting...");

        thread::sleep(Duration::from_secs(3));

        self.setup_all_connections();
        self.monitor_pipe_wire_events();
    }
}

fn main() {
    let mut manager = PipeWireManager::new();
    manager.run();
}
