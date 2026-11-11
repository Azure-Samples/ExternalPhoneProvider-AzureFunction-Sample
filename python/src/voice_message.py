def build_voice_message(message, otp):
    paced_message = message.replace(otp, ", ".join(otp)) if otp else message
    return f"{paced_message} {paced_message}"
