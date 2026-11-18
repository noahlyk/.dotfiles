import requests
import time
import subprocess
from datetime import datetime
import argparse
import os
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--user', help='SSH username')
parser.add_argument('--dry-run', action='store_true', help='prints endpoint found', default=False)
parser.add_argument('command', help='Command to execute remotely', nargs='?', default='')
args = parser.parse_args()

def get_ngrok_token():
    config_path = "~/.config/ngrok/ngrok.yml"
    with open(os.path.expanduser(config_path), 'r') as f:
        config = yaml.safe_load(f)
        return config.get("api_token")

API_KEY = get_ngrok_token()

def get_ngrok_endpoint():
    retries = 0
    while True:
        try:
            response = requests.get(
                "https://api.ngrok.com/endpoints",
                headers={
                    "Authorization": f"Bearer {API_KEY}",
                    "Ngrok-Version": "2"
                }
            )
            response.raise_for_status()
            response = response.json()
            if not response['endpoints']:
                raise ValueError("No endpoints found")
            if retries > 0:
                print()
            return max(
                response['endpoints'],
                key=lambda x: datetime.fromisoformat(x['created_at'].replace('Z', '+00:00'))
            )
        except (requests.RequestException, ValueError):
            if retries == 0:
                print("retrying...", end="", flush=True)
            else:
                print(".", end="", flush=True)
            retries += 1
            time.sleep(5)

newest = get_ngrok_endpoint()
host, port = newest['hostport'].split(':')

user = f"{args.user}@" if args.user else ""
con = f'{user}{host}'

ssh_cmd = ['ssh', '-A', con, '-p', port]
if args.command:
    ssh_cmd.append(args.command)

if args.dry_run:
    print(con, port)
else:
    subprocess.run(ssh_cmd)
