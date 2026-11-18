// ReLiveCompressor.exe - runs the app's scripts inside this process instead of powershell.exe, so Windows
// shows "ReLive Compressor" (name and icon in the taskbar, its right-click menu and Task Manager) and no
// console window can ever open. Lives next to the scripts in the install folder.
//   ReLiveCompressor.exe              open the app (tray + main window)
//   ReLiveCompressor.exe /tray        start quietly in the tray (used at sign-in)
//   ReLiveCompressor.exe /worker [-ScanOnly] [-Recover] [-MaxFiles n]
//   ReLiveCompressor.exe /uninstall
//   ReLiveCompressor.exe /add "file.mp4"   Explorer's "Compress with ReLive Compressor": queue the file for the tray app
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("ReLive Compressor")]
[assembly: AssemblyDescription("ReLive Compressor")]
[assembly: AssemblyProduct("ReLive Compressor")]
[assembly: AssemblyCompany("ReLive Compressor")]
[assembly: AssemblyCopyright("Free to use and share. Provided as is.")]
[assembly: AssemblyVersion("1.6.0.0")]
[assembly: AssemblyFileVersion("1.6.0.0")]

namespace ReLiveCompressorHost
{
    static class AppHost
    {
        [STAThread]
        static int Main(string[] args)
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";
            string script = "ReLiveCompressor.ps1";
            List<KeyValuePair<string, object>> parameters = new List<KeyValuePair<string, object>>();

            if (mode == "/tray") { }
            else if (mode == "/worker") { script = "Worker.ps1"; ParseParameters(args, 1, parameters); }
            else if (mode == "/uninstall") script = "Uninstall.ps1";
            else if (mode == "/add")
            {
                // Explorer starts one of these per selected file; they all append to incoming.txt and the tray app picks them up
                for (int i = 1; i < args.Length; i++) AppendIncoming(dir, args[i]);
                Mutex tray;
                if (Mutex.TryOpenExisting(@"Local\ReLiveCompressorTray", out tray)) { tray.Dispose(); return 0; }
            }
            else parameters.Add(new KeyValuePair<string, object>("Show", true));   // no arguments, or /show

            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;   // only for this process, like -ExecutionPolicy Bypass
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                // the tray icon and WPF window need an STA thread; run the script on this one
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    Command cmd = new Command(Path.Combine(dir, script), false);
                    foreach (KeyValuePair<string, object> p in parameters) cmd.Parameters.Add(p.Key, p.Value);
                    ps.Commands.AddCommand(cmd);
                    try { ps.Invoke(); }
                    catch (Exception ex) { Log(dir, script, ex.ToString()); return 1; }
                    foreach (ErrorRecord e in ps.Streams.Error)
                        Log(dir, script, e + (e.InvocationInfo != null ? " " + e.InvocationInfo.PositionMessage : ""));
                    object code = rs.SessionStateProxy.GetVariable("LASTEXITCODE");
                    return code is int ? (int)code : 0;
                }
            }
        }

        // "-Name value" becomes a parameter with a value, a lone "-Name" a switch
        static void ParseParameters(string[] args, int start, List<KeyValuePair<string, object>> list)
        {
            for (int i = start; i < args.Length; i++)
            {
                if (!args[i].StartsWith("-")) continue;
                string name = args[i].Substring(1);
                if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) { list.Add(new KeyValuePair<string, object>(name, args[i + 1])); i++; }
                else list.Add(new KeyValuePair<string, object>(name, true));
            }
        }

        static void AppendIncoming(string dir, string path)
        {
            for (int attempt = 0; attempt < 50; attempt++)
            {
                try
                {
                    using (FileStream fs = new FileStream(Path.Combine(dir, "incoming.txt"), FileMode.Append, FileAccess.Write, FileShare.None))
                    using (StreamWriter w = new StreamWriter(fs)) w.WriteLine(Path.GetFullPath(path));
                    return;
                }
                catch (IOException) { Thread.Sleep(20); }
            }
        }

        static void Log(string dir, string script, string text)
        {
            try { File.AppendAllText(Path.Combine(dir, "error.log"), DateTime.Now.ToString("s") + " [" + script + "] " + text + Environment.NewLine); }
            catch { }
        }
    }
}
