-- kibo owns the AIRHUG speaker/mic via plain ALSA; keep PipeWire off it.
-- Its idle playback stream otherwise reserves USB bandwidth that starves
-- the capture stream (full-speed device: both 48k streams barely fit).
rule = {
  matches = {
    { { "device.name", "equals", "alsa_card.usb-Generic_AIRHUG_01_AIRHUG_01-00" } },
  },
  apply_properties = { ["device.disabled"] = true },
}
table.insert(alsa_monitor.rules, rule)
