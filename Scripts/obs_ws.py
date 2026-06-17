#!/usr/bin/env python3

import subprocess
from sys import argv, exit
from obsws_python import ReqClient

HOST = "localhost"
PORT = 4455
PASSWORD = ""

USAGE = """\
Usage:
  obs.py start-recording
  obs.py stop-recording
  obs.py toggle-recording
  obs.py toggle-recording-with-music

  obs.py start-replay
  obs.py stop-replay
  obs.py save-replay
  obs.py replay

  obs.py status
"""


def main():
    if len(argv) != 2:
        print(USAGE)
        exit(1)

    cmd = argv[1]

    try:
        obs = ReqClient(
            host=HOST,
            port=PORT,
            password=PASSWORD,
        )

        if cmd == "start-recording":
            obs.start_record()
            print("Recording started")

        elif cmd == "stop-recording":
            obs.stop_record()
            print("Recording stopped")

        elif cmd == "toggle-recording-with-music":
            status = obs.get_record_status()

            if status.output_active:
                obs.stop_record()
                print("Recording stopped")
                subprocess.Popen('/home/fib/Soundboard/play.sh STOP', shell=True)
            else:
                obs.start_record()
                print("Recording started")
                subprocess.Popen('/home/fib/Soundboard/play.sh KC_6', shell=True)

        elif cmd == "toggle-recording":
            status = obs.get_record_status()

            if status.output_active:
                obs.stop_record()
                print("Recording stopped")
            else:
                obs.start_record()
                print("Recording started")

        elif cmd == "start-replay":
            status = obs.get_replay_buffer_status()

            if not status.output_active:
                obs.start_replay_buffer()
                print("Replay buffer started")
            else:
                print("Replay buffer already running")

        elif cmd == "stop-replay":
            status = obs.get_replay_buffer_status()

            if status.output_active:
                obs.stop_replay_buffer()
                print("Replay buffer stopped")
            else:
                print("Replay buffer already stopped")

        elif cmd == "save-replay":
            obs.save_replay_buffer()
            print("Replay saved")

        elif cmd == "replay":
            status = obs.get_replay_buffer_status()
            if not status.output_active:
                obs.start_replay_buffer()
                print("Replay buffer started")
            else:
                obs.save_replay_buffer()
                print("Replay saved")

        elif cmd == "status":
            try:
                rec = obs.get_record_status()
                print(
                    f"Recording: {'ON' if rec.output_active else 'OFF'}"
                )
            except Exception:
                pass

            try:
                replay = obs.get_replay_buffer_status()
                print(
                    f"Replay Buffer: {'ON' if replay.output_active else 'OFF'}"
                )
            except Exception:
                pass

        else:
            print(f"Unknown command: {cmd}")
            print()
            print(USAGE)
            exit(1)

    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == "__main__":
    main()
