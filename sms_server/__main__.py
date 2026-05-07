import logging
import os
import signal
import time

from .modem import Modem
from .notifier import NtfyNotifier

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
)
logger = logging.getLogger('sms_server')


def main() -> None:
    port = os.environ.get('SMS_PORT', '/dev/ttyUSB2')
    baudrate = int(os.environ.get('SMS_BAUDRATE', '115200'))
    ntfy_server = os.environ.get('NTFY_SERVER', 'http://localhost:2586')
    ntfy_topic = os.environ.get('NTFY_TOPIC', 'sms-forward')
    ntfy_priority = os.environ.get('NTFY_PRIORITY', 'default')

    notifier = NtfyNotifier(
        server=ntfy_server,
        topic=ntfy_topic,
        priority=ntfy_priority,
    )

    def on_sms(sender: str, message: str) -> None:
        notifier.notify(sender, message)

    shutdown = False

    def handle_signal(signum: int, frame: object) -> None:
        nonlocal shutdown
        shutdown = True
        logger.info("Shutting down...")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    while not shutdown:
        modem = Modem(port=port, baudrate=baudrate)
        try:
            modem.connect(on_sms)
            logger.info("Listening for SMS on %s, forwarding to %s/%s",
                        port, ntfy_server, ntfy_topic)
            while not shutdown and modem.alive:
                time.sleep(1)
        except Exception as e:
            logger.error("Modem error: %s", e)
        finally:
            modem.close()

        if shutdown:
            break
        logger.info("Reconnecting in 10 seconds...")
        for _ in range(100):
            if shutdown:
                break
            time.sleep(0.1)

    logger.info("Stopped")


if __name__ == '__main__':
    main()
