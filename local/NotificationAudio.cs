using System;
using System.IO;
using System.Text;

// Short, original synthetic sounds: no external files or downloads.
public static class NotificationAudio {
    public static byte[] CreateWave(string profile, int volumePercent) {
        if (profile == "Silent" || profile == "System") return new byte[0];
        if (profile != "Alarm" && profile != "Siren" && profile != "Nuclear") throw new ArgumentException("Unknown sound profile");
        const int rate = 24000;
        double seconds = profile == "Alarm" ? 1.2 : (profile == "Siren" ? 2.4 : 3.0);
        int samples = (int)(seconds * rate);
        double gain = Math.Max(0, Math.Min(100, volumePercent)) / 100.0 * 0.45;
        using (var stream = new MemoryStream())
        using (var writer = new BinaryWriter(stream, Encoding.ASCII)) {
            writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + samples * 2);
            writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
            writer.Write((short)1); writer.Write((short)1); writer.Write(rate);
            writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16);
            writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(samples * 2);
            double phase = 0;
            for (int index = 0; index < samples; index++) {
                double t = index / (double)rate;
                double frequency = profile == "Alarm" ? 880 :
                    (profile == "Siren" ? 650 + 350 * Math.Sin(2 * Math.PI * t / 0.8) :
                     220 + 660 * (0.5 - 0.5 * Math.Cos(2 * Math.PI * t / 1.5)));
                phase += 2 * Math.PI * frequency / rate;
                double wave = Math.Sin(phase);
                if (profile == "Nuclear") wave = (wave + 0.25 * Math.Sin(phase * 2)) / 1.25;
                double envelope = Math.Min(1, t / 0.015) * Math.Min(1, (seconds - t) / 0.04);
                if (profile == "Alarm") {
                    double pulse = t % 0.3;
                    envelope *= Math.Max(0, Math.Min(1, (0.2 - pulse) / 0.015));
                }
                writer.Write((short)(wave * envelope * gain * short.MaxValue));
            }
            writer.Flush(); return stream.ToArray();
        }
    }
}
