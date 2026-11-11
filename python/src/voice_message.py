import re

VOICE_PASSCODE_PATTERN = re.compile(r"(?<![0-9])[0-9]{6}(?![0-9])")


def build_voice_message(message):
    paced_message = VOICE_PASSCODE_PATTERN.sub(
        lambda match: ", ".join(match.group(0)),
        message,
    )
    return f"{paced_message} {paced_message}"
