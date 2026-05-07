import json
import logging
from urllib import request
from urllib.error import URLError

logger = logging.getLogger(__name__)


class NtfyNotifier:
    def __init__(
        self,
        server: str,
        topic: str,
        priority: str = 'default',
        tags: str = 'envelope',
    ):
        self.server = server.rstrip('/')
        self.topic = topic
        self.priority = priority
        self.tags = tags

    def notify(self, sender: str, message: str) -> bool:
        url = f'{self.server}/{self.topic}'
        headers = {
            'Title': f'SMS from {sender}',
            'Priority': self.priority,
            'Tags': self.tags,
        }
        data = message.encode('utf-8')

        req = request.Request(url, data=data, headers=headers, method='POST')
        try:
            with request.urlopen(req, timeout=10) as resp:
                body = resp.read().decode()
                result = json.loads(body)
                logger.info("ntfy published: id=%s", result.get('id', '?'))
                return True
        except URLError as e:
            logger.error("ntfy publish failed: %s", e)
            return False
