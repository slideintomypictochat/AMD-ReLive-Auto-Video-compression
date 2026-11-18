// ReLive Compressor Setup - per-user installer wizard (no admin rights needed).
// The app files and ffmpeg.exe are embedded as payload.zip; see Build-Setup.ps1.
// Compiles with the C# 5 compiler that ships with .NET Framework 4.x.
//   Setup.exe                  normal wizard
//   Setup.exe /extract=<dir>   unpack the payload only (testing)
//   Setup.exe /screens=<dir> [/existing=<dir>]   save a PNG of every page (or the repair/uninstall pages) and exit (testing)
//   Setup.exe /update          started by the app's "Update now": small progress window, same folder and choices, reopens the app
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("ReLive Compressor Setup")]
[assembly: AssemblyDescription("ReLive Compressor Setup")]
[assembly: AssemblyProduct("ReLive Compressor")]
[assembly: AssemblyCompany("ReLive Compressor")]
[assembly: AssemblyCopyright("Free to use and share. Provided as is.")]
[assembly: AssemblyVersion("1.6.1.0")]
[assembly: AssemblyFileVersion("1.6.1.0")]

namespace ReLiveSetup
{
    static class Program
    {
        public const string AppName = "ReLive Compressor";
        public const string Version = "1.6.1";
        public const string Publisher = "ReLive Compressor";
        public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ReLiveCompressor";
        public static string FakeExisting;   // /screens=<dir> /existing=<dir>: render the maintenance pages

        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string extractTo = null, screens = null;
            bool update = false;
            foreach (string a in args)
            {
                if (a.Equals("/update", StringComparison.OrdinalIgnoreCase)) update = true;
                else if (a.StartsWith("/extract=", StringComparison.OrdinalIgnoreCase)) extractTo = a.Substring(9);
                else if (a.StartsWith("/screens=", StringComparison.OrdinalIgnoreCase)) screens = a.Substring(9);
                else if (a.StartsWith("/existing=", StringComparison.OrdinalIgnoreCase)) FakeExisting = a.Substring(10);
            }
            if (screens == null) FakeExisting = null;
            if (extractTo != null) { Payload.Extract(extractTo, null); return 0; }
            if (screens != null) { new SetupForm().SaveScreens(screens); return 0; }

            bool first;
            using (Mutex m = new Mutex(true, @"Local\ReLiveCompressorSetup", out first))
            {
                if (!first) return 1;   // setup is already open
                string version = null, dir = update ? Installer.ExistingInstall(out version) : null;
                if (dir != null && Installer.CompareVersions(version, Version) > 0)
                {
                    MessageBox.Show("A newer version of " + AppName + " (" + version + ") is already installed, so this update (" + Version + ") was not installed.",
                                    AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }
                // no install found: fall back to the normal wizard
                Application.Run(dir != null ? (Form)new UpdateForm(dir) : new SetupForm());
            }
            return 0;
        }
    }

    // ---------- embedded files ----------
    static class Payload
    {
        static ZipArchive Open()
        {
            return new ZipArchive(Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"), ZipArchiveMode.Read);
        }

        public static string ReadText(string name)
        {
            using (ZipArchive z = Open())
            using (StreamReader r = new StreamReader(z.GetEntry(name).Open(), Encoding.UTF8))
                return r.ReadToEnd();
        }

        public static byte[] ReadBytes(string name)
        {
            using (ZipArchive z = Open())
            using (Stream s = z.GetEntry(name).Open())
            using (MemoryStream ms = new MemoryStream())
            {
                s.CopyTo(ms);
                return ms.ToArray();
            }
        }

        public static long TotalSize()
        {
            long n = 0;
            using (ZipArchive z = Open()) foreach (ZipArchiveEntry e in z.Entries) n += e.Length;
            return n;
        }

        // progress(doneBytes, totalBytes, fileName); only entries matching 'only' when given
        public static void Extract(string dir, Action<long, long, string> progress, string only = null)
        {
            Directory.CreateDirectory(dir);
            byte[] buf = new byte[1 << 20];
            using (ZipArchive z = Open())
            {
                long total = 0, done = 0;
                foreach (ZipArchiveEntry e in z.Entries) total += e.Length;
                foreach (ZipArchiveEntry e in z.Entries)
                {
                    if (e.Name.Length == 0) continue;   // folder entry
                    if (only != null && !string.Equals(e.FullName, only, StringComparison.OrdinalIgnoreCase)) continue;
                    string dest = Path.Combine(dir, e.FullName.Replace('/', '\\'));
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    string tmp = dest + ".setup-tmp";
                    using (Stream src = e.Open())
                    using (FileStream fs = File.Create(tmp))
                    {
                        int n;
                        while ((n = src.Read(buf, 0, buf.Length)) > 0)
                        {
                            fs.Write(buf, 0, n);
                            done += n;
                            if (progress != null) progress(done, total, e.Name);
                        }
                    }
                    ReplaceFile(tmp, dest);
                }
            }
        }

        // a just-stopped process can hold its exe for a moment, so retry
        static void ReplaceFile(string tmp, string dest)
        {
            for (int i = 0; ; i++)
            {
                try
                {
                    if (File.Exists(dest)) File.Delete(dest);
                    File.Move(tmp, dest);
                    return;
                }
                catch (IOException) { if (i >= 20) { File.Delete(tmp); throw; } }
                catch (UnauthorizedAccessException) { if (i >= 20) { File.Delete(tmp); throw; } }
                Thread.Sleep(500);
            }
        }
    }

    // ---------- install steps ----------
    static class Installer
    {
        public static string ExistingInstall(out string version)
        {
            if (Program.FakeExisting != null) { version = "1.1"; return Program.FakeExisting; }   // /screens testing only
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Program.UninstallKey))
            {
                string dir = k == null ? null : k.GetValue("InstallLocation") as string;
                version = k == null ? null : k.GetValue("DisplayVersion") as string;
                return dir != null && File.Exists(Path.Combine(dir, "ReLiveCompressor.ps1")) ? dir.TrimEnd('\\') : null;
            }
        }

        // <0 when a is older than b; unreadable versions count as 0
        public static int CompareVersions(string a, string b)
        {
            Version va, vb;
            if (!System.Version.TryParse(a ?? "", out va)) va = new Version(0, 0);
            if (!System.Version.TryParse(b ?? "", out vb)) vb = new Version(0, 0);
            return va.CompareTo(vb);
        }

        public static string StartupShortcut { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), Program.AppName + ".lnk"); } }
        public static string DesktopShortcut { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Program.AppName + ".lnk"); } }

        // tray app, worker, launcher and ffmpeg started from the install folder
        public static void StopRunning(string dir)
        {
            string needle = dir.TrimEnd('\\') + "\\";
            using (ManagementObjectSearcher q = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine, ExecutablePath FROM Win32_Process WHERE Name='ReLiveCompressor.exe' OR Name='powershell.exe' OR Name='wscript.exe' OR Name='ffmpeg.exe'"))
            {
                foreach (ManagementObject p in q.Get())
                {
                    string cmd = (p["CommandLine"] as string) ?? "";
                    string exe = (p["ExecutablePath"] as string) ?? "";
                    if (cmd.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0 && exe.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    try { Process.GetProcessById(Convert.ToInt32(p["ProcessId"])).Kill(); } catch { }
                }
            }
            Thread.Sleep(800);
        }

        // true when this PC's GPU has a working hardware encoder of that name (av1_amf, hevc_amf)
        public static bool ProbeEncoder(string ffmpeg, string encoder)
        {
            ProcessStartInfo psi = new ProcessStartInfo(ffmpeg,
                "-hide_banner -nostdin -loglevel error -f lavfi -i color=black:s=640x360:r=30 -frames:v 3 -c:v " + encoder + " -f null -");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using (Process p = Process.Start(psi))
            {
                if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } return false; }
                return p.ExitCode == 0;
            }
        }

        public static string GpuNames()
        {
            List<string> names = new List<string>();
            try
            {
                using (ManagementObjectSearcher q = new ManagementObjectSearcher("SELECT Name FROM Win32_VideoController"))
                    foreach (ManagementObject o in q.Get())
                    {
                        string n = o["Name"] as string;
                        if (string.IsNullOrEmpty(n) || names.Contains(n) || n.IndexOf("Basic Display", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            n.IndexOf("Virtual", StringComparison.OrdinalIgnoreCase) >= 0) continue;   // skip remote-desktop / VR virtual displays
                        names.Add(n);
                    }
            }
            catch { }
            return names.Count == 0 ? "Unknown graphics card" : string.Join(", ", names.ToArray());
        }

        public static int RunHidden(string exe, string args, out string output)
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe, args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            StringBuilder sb = new StringBuilder();
            using (Process p = new Process())
            {
                p.StartInfo = psi;
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                output = sb.ToString().Trim();
                return p.ExitCode;
            }
        }
    }

    // ---------- look ----------
    static class Theme
    {
        public static readonly Color Bg = Color.FromArgb(16, 16, 16);
        public static readonly Color Header = Color.FromArgb(26, 26, 26);
        public static readonly Color Card = Color.FromArgb(30, 30, 30);
        public static readonly Color Line = Color.FromArgb(44, 44, 44);
        public static readonly Color Text = Color.FromArgb(240, 240, 240);
        public static readonly Color Sub = Color.FromArgb(160, 160, 160);
        public static readonly Color Accent = Color.FromArgb(229, 32, 46);
        public static readonly Color Good = Color.FromArgb(63, 185, 80);
        public static readonly Color Warn = Color.FromArgb(210, 153, 34);

        // same drawing as the app icon: red tile, white play button squeezed by two arrows
        public static void DrawLogo(Graphics g, RectangleF r)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Accent)) g.FillRectangle(b, r);
            float k = r.Width * 0.92f / 24f, ox = r.X + (r.Width - 24 * k) / 2, oy = r.Y + (r.Height - 24 * k) / 2;
            float[][] lines = {
                new float[] { 1, 1, 6.2f, 6.2f }, new float[] { 6.2f, 2.6f, 6.2f, 6.2f }, new float[] { 6.2f, 6.2f, 2.6f, 6.2f },
                new float[] { 23, 23, 17.8f, 17.8f }, new float[] { 17.8f, 21.4f, 17.8f, 17.8f }, new float[] { 17.8f, 17.8f, 21.4f, 17.8f } };
            using (Pen p = new Pen(Color.White, Math.Max(1.3f, 2.0f * k)))
            {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                foreach (float[] l in lines) g.DrawLine(p, ox + l[0] * k, oy + l[1] * k, ox + l[2] * k, oy + l[3] * k);
            }
            using (Pen ring = new Pen(Color.White, Math.Max(1f, 1.6f * k)))
                g.DrawEllipse(ring, ox + 6.1f * k, oy + 6.1f * k, 11.8f * k, 11.8f * k);
            g.FillPolygon(Brushes.White, new PointF[] {
                new PointF(ox + 9.9f * k, oy + 8.4f * k), new PointF(ox + 9.9f * k, oy + 15.6f * k), new PointF(ox + 16 * k, oy + 12 * k) });
        }
    }

    class FlatButton : Button
    {
        public bool Primary;
        bool hover, down;
        public FlatButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            FlatStyle = FlatStyle.Flat;
            Cursor = Cursors.Hand;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Color bg;
            if (!Enabled) bg = Primary ? Color.FromArgb(80, 30, 34) : Color.FromArgb(32, 32, 32);
            else if (Primary) bg = down ? Color.FromArgb(184, 24, 34) : hover ? Color.FromArgb(240, 58, 71) : Theme.Accent;
            else bg = down ? Color.FromArgb(58, 58, 58) : hover ? Color.FromArgb(51, 51, 51) : Color.FromArgb(42, 42, 42);
            using (SolidBrush b = new SolidBrush(bg)) e.Graphics.FillRectangle(b, ClientRectangle);
            if (Focused && ShowFocusCues)
                using (Pen p = new Pen(Color.FromArgb(120, 255, 255, 255))) e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? Color.White : Color.FromArgb(110, 110, 110),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }

    // dark check box / radio button (the system ones draw a white box)
    class DarkCheck : CheckBox
    {
        public DarkCheck() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Cursor = Cursors.Hand; }
        protected override void OnPaint(PaintEventArgs e) { DarkToggle.Paint(this, e.Graphics, Checked, false); }
    }
    class DarkRadio : RadioButton
    {
        public DarkRadio() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Cursor = Cursors.Hand; }
        protected override void OnPaint(PaintEventArgs e) { DarkToggle.Paint(this, e.Graphics, Checked, true); }
    }
    static class DarkToggle
    {
        public static void Paint(Control c, Graphics g, bool on, bool round)
        {
            g.Clear(c.Parent.BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int box = (int)(c.Font.Height * 1.0), y = (c.Height - box) / 2;
            Rectangle r = new Rectangle(1, y, box - 2, box - 2);
            using (SolidBrush fill = new SolidBrush(on ? Theme.Accent : Color.FromArgb(24, 24, 24)))
            using (Pen border = new Pen(on ? Theme.Accent : Color.FromArgb(120, 120, 120), 1.4f))
            {
                if (round) { g.FillEllipse(fill, r); g.DrawEllipse(border, r); }
                else { g.FillRectangle(fill, r); g.DrawRectangle(border, r); }
            }
            if (on)
            {
                if (round)
                {
                    float d = r.Width * 0.4f;
                    g.FillEllipse(Brushes.White, r.X + (r.Width - d) / 2, r.Y + (r.Height - d) / 2, d, d);
                }
                else
                    using (Pen p = new Pen(Color.White, Math.Max(1.6f, r.Width / 8f)))
                        g.DrawLines(p, new PointF[] {
                            new PointF(r.X + r.Width * 0.22f, r.Y + r.Height * 0.52f),
                            new PointF(r.X + r.Width * 0.42f, r.Y + r.Height * 0.72f),
                            new PointF(r.X + r.Width * 0.78f, r.Y + r.Height * 0.30f) });
            }
            Rectangle tr = new Rectangle(box + box / 2, 0, c.Width - box - box / 2, c.Height);
            TextRenderer.DrawText(g, c.Text, c.Font, tr, c.Enabled ? Theme.Text : Theme.Sub,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.WordBreak);
        }
    }

    class ProgressStrip : Control
    {
        double value;
        public double Value { get { return value; } set { this.value = Math.Max(0, Math.Min(100, value)); Invalidate(); } }
        public ProgressStrip() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.FromArgb(42, 42, 42));
            using (SolidBrush b = new SolidBrush(Theme.Accent))
                e.Graphics.FillRectangle(b, 0, 0, (float)(Width * value / 100.0), Height);
        }
    }

    // ---------- update (started by the app) ----------
    // No questions: same folder, keeps Start with Windows / desktop shortcut as they are, settings and log are untouched.
    class UpdateForm : Form
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        readonly string dir;
        readonly Label lblStatus;
        readonly ProgressStrip bar;
        readonly float dpi;
        int S(double v) { return (int)Math.Round(v * dpi); }

        public UpdateForm(string dir)
        {
            this.dir = dir;
            using (Graphics g = CreateGraphics()) dpi = g.DpiX / 96f;
            Text = "Updating " + Program.AppName;
            Font = new Font("Segoe UI", 9.5f);
            BackColor = Theme.Bg; ForeColor = Theme.Text;
            FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; MinimizeBox = false; ControlBox = false;
            StartPosition = FormStartPosition.CenterScreen; AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(S(460), S(130));
            try { Icon = new Icon(new MemoryStream(Payload.ReadBytes("ReLiveCompressor.ico"))); } catch { }
            Panel logo = new Panel { Bounds = new Rectangle(S(24), S(24), S(44), S(44)) };
            logo.Paint += delegate(object s, PaintEventArgs e) { Theme.DrawLogo(e.Graphics, new RectangleF(0, 0, logo.Width, logo.Height)); };
            Controls.Add(logo);
            Controls.Add(new Label { Text = "Updating " + Program.AppName + " to " + Program.Version, Font = new Font("Segoe UI Semibold", 11.5f),
                                     AutoSize = true, Location = new Point(S(84), S(24)) });
            lblStatus = new Label { Text = "Starting...", ForeColor = Theme.Sub, AutoSize = false, Bounds = new Rectangle(S(84), S(52), S(350), S(20)) };
            Controls.Add(lblStatus);
            bar = new ProgressStrip { Bounds = new Rectangle(S(24), S(92), S(412), S(4)) };
            Controls.Add(bar);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int on = 1;
            try { DwmSetWindowAttribute(Handle, 20, ref on, 4); } catch { }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        void Report(string text, double pct)
        {
            BeginInvoke((Action)delegate { if (text != null) lblStatus.Text = text; if (pct >= 0) bar.Value = pct; });
        }

        void Run()
        {
            string error = null;
            try
            {
                bool startup = File.Exists(Installer.StartupShortcut), desktop = File.Exists(Installer.DesktopShortcut);
                Report("Closing ReLive Compressor...", 3);
                Installer.StopRunning(dir);
                Report("Copying files...", 8);
                long last = 0;
                Payload.Extract(dir, delegate(long done, long total, string name)
                {
                    long now = Environment.TickCount;
                    if (now - last < 50 && done < total) return;
                    last = now;
                    Report(null, 8 + 82.0 * done / total);
                });
                Report("Finishing...", 92);
                string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "Install.ps1") + "\" -AppDir \"" + dir + "\"" +
                              " -Version " + Program.Version + " -Publisher \"" + Program.Publisher + "\" -NoLaunch" +
                              (startup ? "" : " -NoStartup") + (desktop ? " -DesktopShortcut" : "");
                string output;
                int code = Installer.RunHidden("powershell.exe", args, out output);
                if (code != 0) error = "The install script reported a problem (exit code " + code + "):\n\n" + output;
                Report("Done", 100);
            }
            catch (Exception ex) { error = ex.Message; }

            BeginInvoke((Action)delegate
            {
                if (error != null)
                    MessageBox.Show(this, "The update could not be completed.\n\n" + error + "\n\nRun ReLive Compressor Setup.exe to repair it. Your recordings are not affected.",
                                    Program.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                try { Process.Start(Path.Combine(dir, "ReLiveCompressor.exe")); } catch { }
                Close();
            });
        }
    }

    // ---------- wizard ----------
    class SetupForm : Form
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        enum Page { Welcome, License, Options, Installing, Finish, Maintain }
        Page page;
        readonly Stack<Page> history = new Stack<Page>();   // for Back
        readonly float dpi;
        readonly Panel header, footer;
        readonly Panel[] pages = new Panel[6];
        readonly FlatButton btnBack, btnNext, btnCancel;
        string headTitle, headSub;

        // page controls
        DarkRadio rbAccept, rbDecline, rbRepair, rbUninstall;
        TextBox licenseBox, txtDir;
        Label lblSpace, lblGpu, lblWelcomeExtra, lblStatus, lblDetail, lblFinish, lblFinishWarn;
        DarkCheck chkStartup, chkDesktop, chkLaunch;
        FlatButton btnBrowse;
        ProgressStrip progress;

        readonly string existing, existingVersion;   // set when the app is already installed (maintenance mode)
        readonly long payloadBytes;
        volatile int gpuState;          // 0 = checking, 1 = AV1, 3 = HEVC only, 2 = no hardware encoder
        string gpuNames = "";
        bool installing, failed, uninstalling, uninstalled;
        string installedDir;

        bool SameVersion { get { return existingVersion == Program.Version; } }

        int S(double v) { return (int)Math.Round(v * dpi); }

        public SetupForm()
        {
            using (Graphics g = CreateGraphics()) dpi = g.DpiX / 96f;
            existing = Installer.ExistingInstall(out existingVersion);
            payloadBytes = Payload.TotalSize();

            Text = Program.AppName + " Setup";
            Font = new Font("Segoe UI", 9.5f);
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(S(700), S(500));
            try { Icon = new Icon(new MemoryStream(Payload.ReadBytes("ReLiveCompressor.ico"))); } catch { }

            header = new Panel { Bounds = new Rectangle(0, 0, ClientSize.Width, S(76)), BackColor = Theme.Header };
            header.Paint += PaintHeader;
            footer = new Panel { Bounds = new Rectangle(0, ClientSize.Height - S(64), ClientSize.Width, S(64)), BackColor = Theme.Bg };
            footer.Paint += delegate(object s, PaintEventArgs e) { using (Pen p = new Pen(Theme.Line)) e.Graphics.DrawLine(p, 0, 0, footer.Width, 0); };
            Controls.Add(header);
            Controls.Add(footer);

            btnCancel = Btn("Cancel", S(700 - 28 - 104), false);
            btnNext = Btn("Next", S(700 - 28 - 104 - 10 - 116), true);
            btnBack = Btn("Back", S(700 - 28 - 104 - 10 - 116 - 8 - 104), false);
            btnNext.Width = S(116);
            footer.Controls.Add(new Label { Text = "Version " + Program.Version, ForeColor = Color.FromArgb(110, 110, 110), AutoSize = true, Location = new Point(S(28), S(24)) });
            btnBack.Click += delegate { if (history.Count > 0) Go(history.Pop(), false); };
            btnNext.Click += delegate { Next(); };
            btnCancel.Click += delegate { Close(); };
            AcceptButton = btnNext;

            for (int i = 0; i < pages.Length; i++)
            {
                pages[i] = new Panel { Bounds = new Rectangle(S(32), S(76 + 24), ClientSize.Width - S(64), ClientSize.Height - S(76 + 24 + 64 + 8)), BackColor = Theme.Bg, Visible = false };
                Controls.Add(pages[i]);
            }
            BuildWelcome(pages[0]);
            BuildLicense(pages[1]);
            BuildOptions(pages[2]);
            BuildInstalling(pages[3]);
            BuildFinish(pages[4]);
            BuildMaintain(pages[5]);
            Go(existing != null ? Page.Maintain : Page.Welcome, false);

            // check the GPU in the background while the user reads the first pages
            ThreadPool.QueueUserWorkItem(delegate { CheckGpu(); });
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int on = 1;
            DwmSetWindowAttribute(Handle, 20, ref on, 4);   // dark title bar (Windows 10 2004+ / 11)
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (installing) { e.Cancel = true; return; }
            if (page != Page.Finish && e.CloseReason == CloseReason.UserClosing &&
                MessageBox.Show(this, "Are you sure you want to cancel setup?\n\n" + Program.AppName + " will not be installed.", Text,
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                e.Cancel = true;
            base.OnFormClosing(e);
        }

        FlatButton Btn(string text, int x, bool primary)
        {
            FlatButton b = new FlatButton { Text = text, Primary = primary, Bounds = new Rectangle(x, S(14), S(104), S(36)), Font = new Font("Segoe UI Semibold", 9.5f) };
            footer.Controls.Add(b);
            return b;
        }

        Label Lbl(Control parent, string text, int x, int y, int w, int h, float pt = 9.5f, Color? color = null, bool bold = false)
        {
            Label l = new Label
            {
                Text = text, Bounds = new Rectangle(x, y, w, h), ForeColor = color ?? Theme.Text, BackColor = Color.Transparent,
                Font = new Font(bold ? "Segoe UI Semibold" : "Segoe UI", pt), UseMnemonic = false
            };
            parent.Controls.Add(l);
            return l;
        }

        void PaintHeader(object sender, PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.DrawLogo(g, new RectangleF(S(28), S(16), S(44), S(44)));
            using (Font f1 = new Font("Segoe UI Semibold", 14f))
            using (Font f2 = new Font("Segoe UI", 9.5f))
            {
                TextRenderer.DrawText(g, headTitle, f1, new Point(S(88), S(12)), Theme.Text);
                TextRenderer.DrawText(g, headSub, f2, new Point(S(90), S(44)), Theme.Sub);
            }
            using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillRectangle(b, 0, header.Height - S(2), header.Width, S(2));
        }

        // ---------- pages ----------
        void BuildWelcome(Panel p)
        {
            int w = p.Width;
            Lbl(p, "Shrink your Radeon ReLive recordings without losing quality.", 0, 0, w, S(28), 12f, null, true);
            Lbl(p,
                "ReLive Compressor re-encodes the game clips that AMD Radeon ReLive saves using your graphics card (AV1, or HEVC on older cards). " +
                "Recordings usually end up 50-80% smaller while keeping their resolution, 60 fps and the original audio.\n\n" +
                "It lives in the notification area next to the clock. Turn on automatic compression and it handles new " +
                "recordings while you're away from the PC, pausing the moment you come back. You can turn it off or " +
                "uninstall it at any time.",
                0, S(36), w, S(142), 10f, Theme.Sub);
            Lbl(p, "REQUIREMENTS", 0, S(186), w, S(20), 8.5f, Theme.Sub, true);
            Lbl(p, "•  Windows 10 or 11 (64-bit)\n•  AMD Radeon RX 400 series or newer graphics card (RX 7000 or newer for AV1)\n•  About " +
                Math.Ceiling(payloadBytes / 1048576.0) + " MB of disk space", 0, S(208), w, S(60), 9.5f);
            lblWelcomeExtra = Lbl(p, existing == null ? "Click Next to continue." :
                "ReLive Compressor is already installed in " + existing + ". Setup will update it and keep your settings and history.",
                0, S(276), w, S(44), 9.5f, existing == null ? Theme.Sub : Theme.Warn);
        }

        void BuildLicense(Panel p)
        {
            int w = p.Width;
            licenseBox = new TextBox
            {
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true, BorderStyle = BorderStyle.None,
                BackColor = Theme.Card, ForeColor = Color.FromArgb(220, 220, 220), Font = new Font("Consolas", 9f),
                Text = Payload.ReadText("License.txt").Replace("\r\n", "\n").Replace("\n", "\r\n"), TabStop = false
            };
            Panel frame = new Panel { Bounds = new Rectangle(0, 0, w, S(232)), BackColor = Theme.Card, Padding = new Padding(S(12), S(10), S(4), S(10)) };
            licenseBox.Dock = DockStyle.Fill;
            frame.Controls.Add(licenseBox);
            p.Controls.Add(frame);
            licenseBox.HandleCreated += delegate { SetWindowTheme(licenseBox.Handle, "DarkMode_Explorer", null); };

            rbAccept = new DarkRadio { Text = "I accept the terms of the license agreement", Bounds = new Rectangle(0, S(244), w, S(26)) };
            rbDecline = new DarkRadio { Text = "I do not accept the terms", Bounds = new Rectangle(0, S(272), w, S(26)), Checked = true };
            rbAccept.CheckedChanged += delegate { UpdateButtons(); };
            p.Controls.Add(rbAccept);
            p.Controls.Add(rbDecline);
        }

        void BuildOptions(Panel p)
        {
            int w = p.Width;
            Lbl(p, "INSTALL FOLDER", 0, 0, w, S(20), 8.5f, Theme.Sub, true);
            string dir = existing ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\ReLive Compressor");
            txtDir = new TextBox { Text = dir, Bounds = new Rectangle(0, S(24), w - S(116), S(28)), BackColor = Theme.Card, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 10f) };
            txtDir.TextChanged += delegate { UpdateSpace(); };
            p.Controls.Add(txtDir);
            btnBrowse = new FlatButton { Text = "Browse...", Bounds = new Rectangle(w - S(104), S(23), S(104), S(30)) };
            btnBrowse.Click += delegate { Browse(); };
            p.Controls.Add(btnBrowse);
            lblSpace = Lbl(p, "", 0, S(58), w, S(20), 9f, Theme.Sub);
            if (existing != null)
            {
                // repair / update keeps the current folder and starts from the current shortcut choices
                txtDir.ReadOnly = true;
                txtDir.BackColor = Color.FromArgb(24, 24, 24);
                txtDir.ForeColor = Theme.Sub;
                btnBrowse.Enabled = false;
            }

            Lbl(p, "OPTIONS", 0, S(96), w, S(20), 8.5f, Theme.Sub, true);
            chkStartup = new DarkCheck { Text = "Start ReLive Compressor when I sign in to Windows (needed for automatic compression)", Bounds = new Rectangle(0, S(120), w, S(26)),
                                         Checked = existing == null || File.Exists(Installer.StartupShortcut) };
            chkDesktop = new DarkCheck { Text = "Create a desktop shortcut", Bounds = new Rectangle(0, S(148), w, S(26)),
                                         Checked = existing != null && File.Exists(Installer.DesktopShortcut) };
            p.Controls.Add(chkStartup);
            p.Controls.Add(chkDesktop);

            Lbl(p, "GRAPHICS CARD", 0, S(190), w, S(20), 8.5f, Theme.Sub, true);
            lblGpu = Lbl(p, "Checking for a hardware video encoder...", 0, S(212), w, S(46), 9.5f, Theme.Sub);
            Lbl(p, existing != null ? "Your settings, compression mode and history are kept." :
                "The app starts in Test mode, which never changes your original recordings. You can pick the recordings folder and mode in the app.",
                0, S(266), w, S(40), 9f, Theme.Sub);
            UpdateSpace();
        }

        void BuildMaintain(Panel p)
        {
            if (existing == null) return;
            int w = p.Width, ind = S(30);
            string ver = string.IsNullOrEmpty(existingVersion) ? "" : " " + existingVersion;
            Lbl(p, "ReLive Compressor" + ver + " is installed in " + existing + ".", 0, 0, w, S(24), 10f, Theme.Sub);
            Lbl(p, "What would you like to do?", 0, S(34), w, S(28), 12f, null, true);

            rbRepair = new DarkRadio { Text = SameVersion ? "Repair" : "Update to version " + Program.Version, Bounds = new Rectangle(0, S(80), w, S(26)), Checked = true, Font = new Font("Segoe UI Semibold", 10.5f) };
            p.Controls.Add(rbRepair);
            Lbl(p, (SameVersion ? "Reinstalls the program files" : "Installs the new version") +
                " and restores the shortcuts and Start menu entries. Your settings, compression mode and history are kept.",
                ind, S(108), w - ind, S(40), 9.5f, Theme.Sub);

            rbUninstall = new DarkRadio { Text = "Uninstall", Bounds = new Rectangle(0, S(166), w, S(26)), Font = new Font("Segoe UI Semibold", 10.5f) };
            p.Controls.Add(rbUninstall);
            Lbl(p, "Removes ReLive Compressor, its shortcuts and its settings from this PC. Your recordings and any test copies are never touched.",
                ind, S(194), w - ind, S(40), 9.5f, Theme.Sub);
            rbUninstall.CheckedChanged += delegate { UpdateButtons(); };
        }

        void BuildInstalling(Panel p)
        {
            int w = p.Width;
            lblStatus = Lbl(p, "Preparing...", 0, S(70), w, S(26), 11f, null, true);
            progress = new ProgressStrip { Bounds = new Rectangle(0, S(104), w, S(6)) };
            p.Controls.Add(progress);
            lblDetail = Lbl(p, "", 0, S(118), w, S(22), 9f, Theme.Sub);
        }

        void BuildFinish(Panel p)
        {
            int w = p.Width;
            lblFinish = Lbl(p, "", 0, 0, w, S(110), 10f, Theme.Sub);
            lblFinishWarn = Lbl(p, "", 0, S(118), w, S(96), 9.5f, Theme.Warn);
            chkLaunch = new DarkCheck { Text = "Open ReLive Compressor now", Bounds = new Rectangle(0, S(232), w, S(26)), Checked = true };
            p.Controls.Add(chkLaunch);
        }

        // ---------- navigation ----------
        void Go(Page to, bool remember = true)
        {
            if (remember && to != page && page != Page.Installing) history.Push(page);
            page = to;
            for (int i = 0; i < pages.Length; i++) pages[i].Visible = i == (int)to;
            switch (to)
            {
                case Page.Welcome: headTitle = "Welcome to ReLive Compressor"; headSub = "This wizard installs ReLive Compressor " + Program.Version + " for your Windows account."; break;
                case Page.Maintain: headTitle = "ReLive Compressor is already installed"; headSub = "Repair or update it, or remove it from this PC."; break;
                case Page.License: headTitle = "License agreement"; headSub = "Please read the terms below. You need to accept them to install."; break;
                case Page.Options:
                    headTitle = existing == null ? "Install options" : SameVersion ? "Repair options" : "Update options";
                    headSub = existing == null ? "Installs for your Windows account only. No administrator rights are needed." : "The install folder stays the same. You can change the shortcuts.";
                    break;
                case Page.Installing:
                    headTitle = uninstalling ? "Uninstalling" : existing == null ? "Installing" : SameVersion ? "Repairing" : "Updating";
                    headSub = "Please wait" + (uninstalling ? " while ReLive Compressor is removed." : "...");
                    break;
                case Page.Finish:
                    if (failed) { headTitle = "Setup could not finish"; headSub = "You can run setup again."; }
                    else if (uninstalled) { headTitle = "ReLive Compressor was removed"; headSub = "Click Finish to close setup."; }
                    else { headTitle = existing == null ? "ReLive Compressor is installed" : SameVersion ? "ReLive Compressor was repaired" : "ReLive Compressor was updated"; headSub = "Click Finish to close setup."; }
                    break;
            }
            header.Invalidate();
            UpdateButtons();
            if (to == Page.Options) UpdateGpuLabel();
        }

        void UpdateButtons()
        {
            btnBack.Visible = history.Count > 0 && page != Page.Installing && page != Page.Finish;
            btnCancel.Visible = page != Page.Finish && page != Page.Installing;
            btnNext.Enabled = !installing && (page != Page.License || rbAccept.Checked);
            btnNext.Visible = page != Page.Installing;
            if (page == Page.Options) btnNext.Text = existing == null ? "Install" : SameVersion ? "Repair" : "Update";
            else if (page == Page.Maintain && rbUninstall != null && rbUninstall.Checked) btnNext.Text = "Uninstall";
            else if (page == Page.Finish) btnNext.Text = failed ? "Close" : "Finish";
            else btnNext.Text = "Next";
        }

        void Next()
        {
            switch (page)
            {
                case Page.Welcome: Go(Page.License); break;
                case Page.Maintain:
                    if (rbUninstall.Checked)
                    {
                        if (MessageBox.Show(this, "Remove ReLive Compressor from this PC?\n\nYour recordings and any test copies are not touched.", Text,
                                MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                            StartUninstall();
                    }
                    else Go(SameVersion ? Page.Options : Page.License);   // an update shows the (possibly changed) terms again
                    break;
                case Page.License: if (rbAccept.Checked) Go(Page.Options); break;
                case Page.Options:
                    string dir, problem = CheckDir(txtDir.Text, out dir);
                    if (problem != null) { MessageBox.Show(this, problem, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
                    if (gpuState == 2 && MessageBox.Show(this,
                            "This PC's graphics card doesn't seem to have a hardware video encoder (AV1 or HEVC), so ReLive Compressor won't be able to compress anything.\n\nInstall anyway?",
                            Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                    StartInstall(dir);
                    break;
                case Page.Finish:
                    if (!failed && !uninstalled && chkLaunch.Checked)
                        try { Process.Start(Path.Combine(installedDir, "ReLiveCompressor.exe")); } catch { }
                    Close();
                    break;
            }
        }

        // returns an error message, or null when the folder is fine
        string CheckDir(string input, out string dir)
        {
            dir = null;
            try { dir = Path.GetFullPath(Environment.ExpandEnvironmentVariables(input.Trim())).TrimEnd('\\'); }
            catch { return "That isn't a valid folder path."; }
            if (!Path.IsPathRooted(dir) || dir.Length <= 3) return "Please choose a folder, not the root of a drive.";
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            if (dir.StartsWith(win, StringComparison.OrdinalIgnoreCase)) return "Please choose a folder outside the Windows folder.";
            // uninstall removes the install folder, so never install into a folder that holds other things
            if (Directory.Exists(dir) && !File.Exists(Path.Combine(dir, "ReLiveCompressor.ps1")) && Directory.GetFileSystemEntries(dir).Length > 0)
                return "That folder already contains other files.\n\nPlease choose an empty or new folder, for example:\n" + Path.Combine(dir, "ReLive Compressor");
            try
            {
                Directory.CreateDirectory(dir);
                string probe = Path.Combine(dir, ".setup-write-test");
                File.WriteAllText(probe, "");
                File.Delete(probe);
            }
            catch { return "Setup can't write to that folder. Please choose a folder in your user profile, for example:\n" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\ReLive Compressor"); }
            if (!Directory.Exists(Path.GetPathRoot(dir))) return "That drive isn't available.";
            if (new DriveInfo(Path.GetPathRoot(dir)).AvailableFreeSpace < payloadBytes + 20L * 1048576)
                return "There isn't enough free space on that drive.";
            return null;
        }

        void Browse()
        {
            using (FolderBrowserDialog d = new FolderBrowserDialog { Description = "Choose where to install ReLive Compressor. A \"ReLive Compressor\" folder is created inside it.", ShowNewFolderButton = true })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                string picked = d.SelectedPath.TrimEnd('\\');
                txtDir.Text = picked.EndsWith("ReLive Compressor", StringComparison.OrdinalIgnoreCase) ? picked : Path.Combine(picked, "ReLive Compressor");
            }
        }

        void UpdateSpace()
        {
            string text = "Space required: " + Math.Ceiling(payloadBytes / 1048576.0) + " MB";
            try
            {
                string root = Path.GetPathRoot(Path.GetFullPath(txtDir.Text.Trim()));
                DriveInfo d = new DriveInfo(root);
                if (d.IsReady) text += "      Free on drive " + root.TrimEnd('\\') + " " + (d.AvailableFreeSpace / 1073741824.0).ToString("0.0") + " GB";
            }
            catch { }
            lblSpace.Text = text;
        }

        // ---------- GPU check ----------
        void CheckGpu()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "ReLiveCompressorSetup-" + Process.GetCurrentProcess().Id);
            int state = 2;
            try
            {
                gpuNames = Installer.GpuNames();
                Payload.Extract(tmp, null, "ffmpeg.exe");
                string ff = Path.Combine(tmp, "ffmpeg.exe");
                state = Installer.ProbeEncoder(ff, "av1_amf") ? 1 : Installer.ProbeEncoder(ff, "hevc_amf") ? 3 : 2;
            }
            catch { state = 2; }
            finally { try { Directory.Delete(tmp, true); } catch { } }
            gpuState = state;
            try { BeginInvoke((Action)UpdateGpuLabel); } catch { }
        }

        void UpdateGpuLabel()
        {
            if (lblGpu == null) return;
            if (gpuState == 0) { lblGpu.Text = "Checking for a hardware video encoder..."; lblGpu.ForeColor = Theme.Sub; }
            else if (gpuState == 1) { lblGpu.Text = gpuNames + "\nAV1 hardware encoding is supported (smallest files)."; lblGpu.ForeColor = Theme.Good; }
            else if (gpuState == 3) { lblGpu.Text = gpuNames + "\nHEVC hardware encoding is supported. Files end up a little larger than with AV1 (RX 7000 or newer)."; lblGpu.ForeColor = Theme.Good; }
            else
            {
                lblGpu.Text = gpuNames + "\nNo hardware video encoder found. Compression needs an AMD Radeon RX 400 series or newer with a current driver.";
                lblGpu.ForeColor = Theme.Warn;
            }
        }

        // ---------- install ----------
        void StartInstall(string dir)
        {
            installing = true;
            installedDir = dir;
            ControlBox = false;
            Go(Page.Installing);
            bool startup = chkStartup.Checked, desktop = chkDesktop.Checked;
            Thread t = new Thread(delegate() { RunInstall(dir, startup, desktop); });
            t.IsBackground = true;
            t.Start();
        }

        void Report(string status, double pct, string detail)
        {
            BeginInvoke((Action)delegate
            {
                if (status != null) lblStatus.Text = status;
                if (pct >= 0) progress.Value = pct;
                lblDetail.Text = detail ?? "";
            });
        }

        void RunInstall(string dir, bool startup, bool desktop)
        {
            string error = null;
            try
            {
                Report("Closing ReLive Compressor if it's running...", 2, null);
                Installer.StopRunning(dir);

                Report("Copying files...", 5, null);
                long lastTick = 0;
                Payload.Extract(dir, delegate(long done, long total, string name)
                {
                    long now = Environment.TickCount;
                    if (now - lastTick < 50 && done < total) return;
                    lastTick = now;
                    Report(null, 5 + 80.0 * done / total, name);
                });

                Report("Creating shortcuts...", 88, null);
                string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "Install.ps1") + "\" -AppDir \"" + dir + "\"" +
                              " -Version " + Program.Version + " -Publisher \"" + Program.Publisher + "\" -NoLaunch" +
                              (startup ? "" : " -NoStartup") + (desktop ? " -DesktopShortcut" : "");
                string output;
                int code = Installer.RunHidden("powershell.exe", args, out output);
                if (code != 0) error = "The install script reported a problem (exit code " + code + "):\n\n" + output;
                Report("Done", 100, null);
            }
            catch (Exception ex) { error = ex.Message; }

            BeginInvoke((Action)delegate { FinishInstall(error); });
        }

        // ---------- uninstall ----------
        void StartUninstall()
        {
            installing = uninstalling = true;
            installedDir = existing;
            ControlBox = false;
            Go(Page.Installing);
            Thread t = new Thread(delegate() { RunUninstall(existing); });
            t.IsBackground = true;
            t.Start();
        }

        // runs this setup's own copy of Uninstall.ps1 from a temp folder, so it can delete the install folder and we can wait for it
        void RunUninstall(string dir)
        {
            string error = null;
            string tmp = Path.Combine(Path.GetTempPath(), "ReLiveCompressorSetup-" + Process.GetCurrentProcess().Id);
            try
            {
                Report("Closing ReLive Compressor...", 10, null);
                Installer.StopRunning(dir);
                Report("Removing files, shortcuts and settings...", 40, null);
                Payload.Extract(tmp, null, "Uninstall.ps1");
                string output, ver;
                int code = Installer.RunHidden("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(tmp, "Uninstall.ps1") + "\" -AppDir \"" + dir + "\" -Quiet", out output);
                if (code != 0) error = "The uninstall script reported a problem (exit code " + code + "):\n\n" + output;
                else if (Installer.ExistingInstall(out ver) != null) error = "ReLive Compressor is still registered as installed.\n\n" + output;
                Report("Done", 100, null);
            }
            catch (Exception ex) { error = ex.Message; }
            finally { try { Directory.Delete(tmp, true); } catch { } }

            BeginInvoke((Action)delegate { FinishUninstall(error); });
        }

        void FinishUninstall(string error)
        {
            installing = false;
            ControlBox = true;
            chkLaunch.Visible = false;
            if (error != null) { FinishInstall(error); return; }
            uninstalled = true;
            lblFinish.Text = "ReLive Compressor, its shortcuts, Start menu entries and settings were removed from this PC.\n\n" +
                             "Your recordings and any test copies were not touched.";
            lblFinishWarn.Text = Directory.Exists(installedDir)
                ? "Some files could not be deleted. You can delete this folder yourself:\n" + installedDir
                : "";
            Go(Page.Finish);
        }

        void FinishInstall(string error)
        {
            installing = false;
            failed = error != null;
            ControlBox = true;
            if (failed)
            {
                lblFinish.Text = "Something went wrong" + (uninstalling ? " while uninstalling:" : " while installing:");
                lblFinishWarn.Text = error.Length > 600 ? error.Substring(0, 600) + "..." : error;
                lblFinishWarn.Height = S(190);
                chkLaunch.Visible = false;
            }
            else
            {
                lblFinish.Text =
                    "ReLive Compressor was " + (existing == null ? "installed to " : SameVersion ? "repaired in " : "updated to version " + Program.Version + " in ") + installedDir + ".\n\n" +
                    "Find it in the Start menu, or click its icon in the notification area next to the clock. " +
                    (existing != null
                        ? "Your settings and history were kept."
                        : "It starts in Test mode: Compress now makes a few test copies so you can compare them before choosing Replace or Move in Settings.");
                lblFinishWarn.Text = gpuState == 2
                    ? "Note: no hardware video encoder was found on this PC, so compression won't work until it runs on an AMD Radeon RX 400 series or newer graphics card."
                    : "";
            }
            Go(Page.Finish);
        }

        // ---------- testing: render each page to PNG without showing the window ----------
        public void SaveScreens(string dir)
        {
            Directory.CreateDirectory(dir);
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-5000, -5000);
            ShowInTaskbar = false;
            Show();
            for (int i = 0; i < 300 && gpuState == 0; i++) { Application.DoEvents(); Thread.Sleep(50); }
            Application.DoEvents();
            Action<string> snap = delegate(string name)
            {
                Application.DoEvents();
                using (Bitmap b = new Bitmap(Width, Height))
                {
                    DrawToBitmap(b, new Rectangle(0, 0, Width, Height));
                    b.Save(Path.Combine(dir, name + ".png"));
                }
            };
            installedDir = existing ?? txtDir.Text;
            if (existing != null)
            {
                Go(Page.Maintain); snap("0-maintain");
                Go(Page.Options); snap("3-options");
                rbUninstall.Checked = true; Go(Page.Maintain); snap("0-maintain-uninstall");
                uninstalling = true; Go(Page.Installing); lblStatus.Text = "Removing files, shortcuts and settings..."; progress.Value = 40; snap("4-uninstalling");
                FinishUninstall(null); snap("5-uninstalled");
            }
            else
            {
                Go(Page.Welcome); snap("1-welcome");
                Go(Page.License); rbAccept.Checked = true; snap("2-license");
                Go(Page.Options); snap("3-options");
                Go(Page.Installing); lblStatus.Text = "Copying files..."; progress.Value = 46; lblDetail.Text = "ffmpeg.exe"; snap("4-installing");
                FinishInstall(null); snap("5-finish");
            }
            installing = false; failed = true; page = Page.Finish;
            Hide();
        }
    }
}
