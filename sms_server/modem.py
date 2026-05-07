import logging
import threading

from ._gsmmodem.modem import GsmModem, ReceivedSms

logger = logging.getLogger(__name__)


class Modem:
    def __init__(self, port: str, baudrate: int = 115200):
        self.port = port
        self.baudrate = baudrate
        self._modem: GsmModem | None = None

    def connect(self, on_sms) -> None:
        def sms_handler(sms: ReceivedSms) -> None:
            logger.info("SMS received from %s: %s", sms.number, sms.text)
            on_sms(sms.number, sms.text)

        self._modem = GsmModem(
            port=self.port,
            baudrate=self.baudrate,
            smsReceivedCallbackFunc=sms_handler,
        )
        self._modem.connect()
        logger.info("Modem connected on %s, waiting for SMS", self.port)

    @property
    def alive(self) -> bool:
        return self._modem is not None and self._modem.alive

    def close(self) -> None:
        if self._modem is not None:
            try:
                self._modem.close()
            except Exception:
                pass
            self._modem = None
