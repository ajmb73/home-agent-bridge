#!/usr/bin/env python3
"""
Price watch script for Amazon.ca products.
Fetches prices and alerts via Telegram when prices drop below threshold.
"""
import subprocess
import re
import os
import time
from datetime import datetime
from pathlib import Path

# Configuration
HOME = os.environ.get('HOME', '/home/ale')
LOG_FILE = Path(HOME) / '.hermes' / 'logs' / 'price-watch.log'
PRICE_FILE = Path(HOME) / '.hermes' / 'data' / 'last-prices.txt'
TELEGRAM_CHAT_ID = '292353410'

# Products: name -> (asin, threshold, url)
PRODUCTS = {
    "MINISFORUM UM890 Pro": ("B0DHV3F5YD", 700.00, "https://www.amazon.ca/dp/B0DHV3F5YD"),
    "GEEKOM A7 Max":        ("B0G2BZG62Y", 750.00, "https://www.amazon.ca/dp/B0G2BZG62Y"),
    "Beelink SER5 MAX":     ("B0DPWGP2KM", 550.00, "https://www.amazon.ca/dp/B0DPWGP2KM"),
    "GEEKOM A8":            ("B0DY758WPX", 650.00, "https://www.amazon.ca/dp/B0DY758WPX"),
    "BOSGAME P3":           ("B0GFLZJC3C", 800.00, "https://www.amazon.ca/dp/B0GFLZJC3C"),
}

# Headers for Amazon request (NO --compressed flag)
AMAZON_HEADERS = [
    "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Accept-Language: en-CA,en",
]


def get_timestamp():
    """Return current time as HH:MM."""
    return datetime.now().strftime('%H:%M')


def log(message):
    """Append timestamped message to log file only (silent operation)."""
    timestamp = get_timestamp()
    line = f"[{timestamp}] {message}\n"
    with open(LOG_FILE, 'a') as f:
        f.write(line)


def load_previous_prices():
    """Load previous prices from price file. Returns dict: asin -> price_str."""
    prices = {}
    if PRICE_FILE.exists():
        for line in PRICE_FILE.read_text().splitlines():
            parts = line.strip().split('|')
            if len(parts) == 2:
                prices[parts[0]] = parts[1]
    return prices


def save_prices(prices):
    """Save current prices to price file. Format: ASIN|PRICE per line."""
    PRICE_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{asin}|{price}" for asin, price in prices.items()]
    PRICE_FILE.write_text('\n'.join(lines) + '\n')


def fetch_price(asin):
    """
    Fetch price from Amazon.ca product page using curl.
    Returns price string like "699.99" or None if unavailable.
    """
    url = f"https://www.amazon.ca/dp/{asin}"
    try:
        result = subprocess.run(
            ['curl', '-s', '--max-time', '20', url,
             '-H', AMAZON_HEADERS[0],
             '-H', AMAZON_HEADERS[1]],
            capture_output=True,
            text=True,
            timeout=25
        )
        html = result.stdout

        # Amazon returns small page (redirect/block) if not full HTML
        if len(html) < 5000:
            return None

        # Extract whole part
        whole_match = re.search(r'class="a-price-whole">([^<]+)', html)
        if not whole_match:
            return None

        # Extract fraction part
        frac_match = re.search(r'class="a-price-fraction">([^<]+)', html)
        frac = frac_match.group(1) if frac_match else '00'

        return f"{whole_match.group(1)}.{frac}"
    except Exception:
        return None


def get_bot_token():
    """Extract bot token from Proton Pass Agents vault via pass-cli."""
    try:
        env = os.environ.copy()
        env["PROTON_PASS_AGENT_REASON"] = "Price watch: reading Telegram bot token"
        result = subprocess.run(
            ["pass-cli", "item", "view",
             "--share-id", "3RhkIoczlcY4AzztkKZYb5-mxxu8aNzwPWBNO40gGJm1nZ5LZksnyJaF_t-iYDtvusmigdbsPfj0YbWvAqxSrg==",
             "--item-title", "Jax_bot Telegram Token",
             "--field", "note"],
            capture_output=True, text=True, timeout=15, env=env
        )
        if result.returncode == 0:
            return result.stdout.strip()
        log(f"pass-cli failed (rc={result.returncode}): {result.stderr.strip()}")
    except Exception as e:
        log(f"pass-cli error: {e}")
    return None


def send_telegram_alert(name, price, threshold, url):
    """Send price drop alert via Telegram."""
    token = get_bot_token()
    if not token or len(token) < 10:
        return False

    savings = round(threshold - float(price), 2)
    # Escape Markdown special characters in name
    safe_name = name.replace('_', '\\_').replace('*', '\\*').replace('[', '\\[').replace('`', '\\`')
    message = f"""Price Drop Alert

*{safe_name}*
Current: ${price} CAD
Threshold: ${threshold} CAD
Savings: ${savings} below threshold

{url}"""

    try:
        result = subprocess.run(
            ['curl', '-s', '-X', 'POST',
             f'https://api.telegram.org/bot{token}/sendMessage',
             '-d', f'chat_id={TELEGRAM_CHAT_ID}&text={message}&parse_mode=Markdown',
             '--max-time', '10'],
            capture_output=True,
            timeout=15
        )
        return result.returncode == 0
    except Exception:
        return False


def main():
    # Load previous prices
    previous_prices = load_previous_prices()

    # Track current prices and alert status
    current_prices = {}
    alert_sent = False

    log('Checking prices...')

    for name, (asin, threshold, url) in PRODUCTS.items():
        price = fetch_price(asin)

        if price is None:
            log(f'WARN: {name} -- unavailable')
            time.sleep(5)
            continue

        # Log price in required format
        log(f'{name} -- ${price} CAD')

        current_prices[asin] = price

        # Check if price dropped below threshold AND changed since last run
        previous_price = previous_prices.get(asin)
        if previous_price is not None:
            price_changed = (price != previous_price)
        else:
            price_changed = True

        if float(price) <= threshold and price_changed:
            log(f'ALERT: {name} -- ${price} CAD below threshold ${threshold}')
            if send_telegram_alert(name, price, threshold, url):
                alert_sent = True

        time.sleep(5)

    # Save current prices
    save_prices(current_prices)

    # Log completion
    if alert_sent:
        log('Done -- alert sent.')
    else:
        log('Done.')


if __name__ == '__main__':
    main()
