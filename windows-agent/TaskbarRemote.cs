using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace TaskbarRemote
{
    static class Program
    {
        private static Mutex single;
        public static EventWaitHandle ShowEvent;

        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length > 0 &&
                string.Equals(args[0], "--uninstall", StringComparison.OrdinalIgnoreCase))
            {
                Setup.Uninstall();
                return;
            }

            bool created;
            single = new Mutex(true, "TaskbarRemoteSingleInstance", out created);
            bool createdEvent;
            ShowEvent = new EventWaitHandle(false, EventResetMode.AutoReset,
                "TaskbarRemoteShowEvent", out createdEvent);

            if (!created)
            {
                // Already running -> ask that instance to show its window, then exit.
                try { ShowEvent.Set(); } catch { }
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool portableArg = args.Length > 0 &&
                string.Equals(args[0], "--portable", StringComparison.OrdinalIgnoreCase);

            if (!Setup.IsInstalled() && !portableArg)
            {
                var wizard = new SetupForm();
                Application.Run(wizard);
                if (!wizard.RunPortable)
                {
                    GC.KeepAlive(single);
                    return; // installed & handed off, or cancelled
                }
            }

            Application.Run(new MainForm());
            GC.KeepAlive(single);
        }

        public static void ReleaseSingleInstance()
        {
            try
            {
                if (single != null)
                {
                    single.ReleaseMutex();
                    single.Dispose();
                    single = null;
                }
            }
            catch { }
        }
    }

    // ---- Setup wizard shown the first time (before install) ----
    public class SetupForm : Form
    {
        public bool RunPortable = false;

        public SetupForm()
        {
            this.Text = "Taskbar Remote Setup";
            this.ClientSize = new Size(470, 300);
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
            this.StartPosition = FormStartPosition.CenterScreen;
            try { this.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }

            var title = new Label();
            title.Text = "Install Taskbar Remote";
            title.Font = new Font(this.Font.FontFamily, 14, FontStyle.Bold);
            title.SetBounds(24, 22, 420, 30);

            var desc = new Label();
            desc.Text =
                "This sets up Taskbar Remote on your PC so it:\r\n\r\n" +
                "    •  appears in your Start Menu\r\n" +
                "    •  shows in Settings › Apps (with an Uninstall button)\r\n" +
                "    •  starts automatically with Windows\r\n" +
                "    •  stays safe from accidental deletion\r\n\r\n" +
                "It connects this PC to the phone app over Wi-Fi.";
            desc.SetBounds(26, 64, 420, 150);

            var installBtn = new Button();
            installBtn.Text = "Install";
            installBtn.SetBounds(250, 250, 95, 32);
            installBtn.Click += new EventHandler(OnInstall);

            var portableBtn = new Button();
            portableBtn.Text = "Just run once";
            portableBtn.SetBounds(120, 250, 120, 32);
            portableBtn.Click += new EventHandler(OnPortable);

            var cancelBtn = new Button();
            cancelBtn.Text = "Cancel";
            cancelBtn.SetBounds(355, 250, 95, 32);
            cancelBtn.Click += new EventHandler(OnCancel);

            this.Controls.Add(title);
            this.Controls.Add(desc);
            this.Controls.Add(portableBtn);
            this.Controls.Add(installBtn);
            this.Controls.Add(cancelBtn);
            this.AcceptButton = installBtn;
            this.CancelButton = cancelBtn;
        }

        private void OnInstall(object sender, EventArgs e)
        {
            try
            {
                Setup.Install();
                MessageBox.Show(this,
                    "Installed!\r\n\r\nTaskbar Remote is now in your Start Menu and in " +
                    "Settings › Apps. It will start with Windows.\r\n\r\n" +
                    "You can delete the file you downloaded — the installed copy is safe.",
                    "Taskbar Remote", MessageBoxButtons.OK, MessageBoxIcon.Information);
                Program.ReleaseSingleInstance();
                Setup.LaunchInstalled();
                this.RunPortable = false;
                this.Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Install failed: " + ex.Message,
                    "Taskbar Remote", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OnPortable(object sender, EventArgs e)
        {
            this.RunPortable = true;
            this.Close();
        }

        private void OnCancel(object sender, EventArgs e)
        {
            this.RunPortable = false;
            this.Close();
        }
    }

    // ---- The actual app window + tray ----
    public class MainForm : Form
    {
        private const string RunKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string RunName = "TaskbarRemoteAgent";

        private NotifyIcon tray;
        private TextBox ipBox;
        private TextBox tokenBox;
        private TextBox logBox;
        private Label statusLabel;
        private CheckBox startupCheck;
        private Process agent;
        private bool reallyExit = false;
        private bool listening = true;
        private string configPath;

        public MainForm()
        {
            configPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TaskbarRemote", "config.txt");
            BuildUi();
            BuildTray();
            LoadConfig();
            startupCheck.Checked = IsStartupEnabled();
            startupCheck.CheckedChanged += new EventHandler(OnStartupCheck);

            var t = new Thread(ShowListener);
            t.IsBackground = true;
            t.Start();

            StartAgent();
        }

        private void BuildUi()
        {
            this.Text = "Taskbar Remote Agent";
            this.ClientSize = new Size(520, 400);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.MinimumSize = new Size(440, 360);
            try { this.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }

            var ipLabel = new Label();
            ipLabel.Text = "Phone IP";
            ipLabel.SetBounds(16, 20, 90, 22);
            ipBox = new TextBox();
            ipBox.SetBounds(110, 17, 180, 24);

            var tokenLabel = new Label();
            tokenLabel.Text = "Token";
            tokenLabel.SetBounds(16, 52, 90, 22);
            tokenBox = new TextBox();
            tokenBox.SetBounds(110, 49, 260, 24);

            var connectBtn = new Button();
            connectBtn.Text = "Save && Connect";
            connectBtn.SetBounds(110, 82, 130, 28);
            connectBtn.Click += new EventHandler(OnConnectClick);

            statusLabel = new Label();
            statusLabel.Text = "Starting...";
            statusLabel.SetBounds(256, 88, 250, 22);
            statusLabel.ForeColor = Color.DarkOrange;

            startupCheck = new CheckBox();
            startupCheck.Text = "Start with Windows";
            startupCheck.SetBounds(110, 118, 220, 22);

            var logLabel = new Label();
            logLabel.Text = "Activity log:";
            logLabel.SetBounds(16, 150, 120, 22);

            logBox = new TextBox();
            logBox.SetBounds(16, 174, 488, 210);
            logBox.Multiline = true;
            logBox.ScrollBars = ScrollBars.Vertical;
            logBox.ReadOnly = true;
            logBox.BackColor = Color.FromArgb(20, 24, 28);
            logBox.ForeColor = Color.Gainsboro;
            logBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;

            this.Controls.Add(ipLabel);
            this.Controls.Add(ipBox);
            this.Controls.Add(tokenLabel);
            this.Controls.Add(tokenBox);
            this.Controls.Add(connectBtn);
            this.Controls.Add(statusLabel);
            this.Controls.Add(startupCheck);
            this.Controls.Add(logLabel);
            this.Controls.Add(logBox);

            this.FormClosing += new FormClosingEventHandler(OnFormClosing);
        }

        private void BuildTray()
        {
            tray = new NotifyIcon();
            try { tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { tray.Icon = SystemIcons.Application; }
            tray.Text = "Taskbar Remote Agent";
            tray.Visible = true;
            tray.DoubleClick += new EventHandler(OnTrayOpen);

            var menu = new ContextMenuStrip();
            var openItem = new ToolStripMenuItem("Open");
            openItem.Click += new EventHandler(OnTrayOpen);
            menu.Items.Add(openItem);
            if (!Setup.IsInstalled())
            {
                var installItem = new ToolStripMenuItem("Install on this PC");
                installItem.Click += new EventHandler(OnTrayInstall);
                menu.Items.Add(installItem);
            }
            var exitItem = new ToolStripMenuItem("Exit");
            exitItem.Click += new EventHandler(OnTrayExit);
            menu.Items.Add(exitItem);
            tray.ContextMenuStrip = menu;
        }

        private void ShowListener()
        {
            while (listening)
            {
                try { Program.ShowEvent.WaitOne(); } catch { break; }
                if (!listening) break;
                try { this.BeginInvoke(new Action(ShowFromTray)); } catch { }
            }
        }

        private void ShowFromTray()
        {
            this.Show();
            this.WindowState = FormWindowState.Normal;
            this.Activate();
            this.BringToFront();
        }

        private void OnTrayOpen(object sender, EventArgs e) { ShowFromTray(); }

        private void OnTrayInstall(object sender, EventArgs e)
        {
            try
            {
                SaveConfig();
                Setup.Install();
                MessageBox.Show(this,
                    "Installed! Find 'Taskbar Remote' in the Start Menu, and in Settings › Apps.",
                    "Taskbar Remote", MessageBoxButtons.OK, MessageBoxIcon.Information);
                reallyExit = true;
                StopAgent();
                tray.Visible = false;
                Program.ReleaseSingleInstance();
                Setup.LaunchInstalled();
                Application.Exit();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Install failed: " + ex.Message,
                    "Taskbar Remote", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OnTrayExit(object sender, EventArgs e)
        {
            reallyExit = true;
            listening = false;
            StopAgent();
            tray.Visible = false;
            Application.Exit();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!reallyExit && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                this.Hide();
                tray.ShowBalloonTip(3000, "Taskbar Remote",
                    "Still running in the background. Right-click the tray icon and choose Exit to quit.",
                    ToolTipIcon.Info);
            }
        }

        private void OnConnectClick(object sender, EventArgs e)
        {
            SaveConfig();
            StartAgent();
        }

        private string ExtractAgent()
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TaskbarRemote");
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "taskbar-agent.exe");
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("agent"))
                {
                    if (s == null) { AppendLog("ERROR: embedded agent missing."); return path; }
                    var write = true;
                    if (File.Exists(path) && new FileInfo(path).Length == s.Length) write = false;
                    if (write)
                    {
                        using (var f = File.Create(path)) { s.CopyTo(f); }
                    }
                }
            }
            catch (Exception ex) { AppendLog("Could not unpack agent: " + ex.Message); }
            return path;
        }

        private void StartAgent()
        {
            StopAgent();
            var exe = ExtractAgent();
            if (!File.Exists(exe))
            {
                AppendLog("ERROR: could not prepare the agent.");
                SetStatus("Agent error", Color.Red);
                return;
            }
            var ip = ipBox.Text.Trim();
            var token = tokenBox.Text.Trim();
            if (ip.Length == 0 || token.Length == 0)
            {
                AppendLog("Enter the Phone IP and Token shown in the phone app, then click Save & Connect.");
                SetStatus("Need IP + token", Color.DarkOrange);
                return;
            }
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = exe;
                psi.Arguments = "--host " + ip + " --port 8765 --token " + token;
                psi.WorkingDirectory = Path.GetDirectoryName(exe);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                agent = new Process();
                agent.StartInfo = psi;
                agent.EnableRaisingEvents = true;
                agent.OutputDataReceived += new DataReceivedEventHandler(OnAgentOutput);
                agent.ErrorDataReceived += new DataReceivedEventHandler(OnAgentOutput);
                agent.Start();
                agent.BeginOutputReadLine();
                agent.BeginErrorReadLine();
                AppendLog("Agent started -> " + ip + ":8765");
                SetStatus("Connecting...", Color.DarkOrange);
            }
            catch (Exception ex)
            {
                AppendLog("Failed to start agent: " + ex.Message);
                SetStatus("Error", Color.Red);
            }
        }

        private void OnAgentOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) return;
            AppendLog(e.Data);
            if (e.Data.IndexOf("Connected to phone", StringComparison.OrdinalIgnoreCase) >= 0)
                SetStatus("Connected", Color.ForestGreen);
            else if (e.Data.IndexOf("Disconnected", StringComparison.OrdinalIgnoreCase) >= 0)
                SetStatus("Disconnected - retrying", Color.DarkOrange);
            else if (e.Data.IndexOf("Connection failed", StringComparison.OrdinalIgnoreCase) >= 0)
                SetStatus("Waiting for phone...", Color.DarkOrange);
        }

        private void StopAgent()
        {
            try
            {
                if (agent != null && !agent.HasExited) agent.Kill();
            }
            catch { }
            agent = null;
        }

        private void AppendLog(string line)
        {
            if (logBox.InvokeRequired)
            {
                logBox.BeginInvoke(new Action<string>(AppendLog), line);
                return;
            }
            if (logBox.TextLength > 8000)
                logBox.Text = logBox.Text.Substring(logBox.TextLength - 4000);
            logBox.AppendText(line + Environment.NewLine);
        }

        private void SetStatus(string text, Color color)
        {
            if (statusLabel.InvokeRequired)
            {
                statusLabel.BeginInvoke(new Action<string, Color>(SetStatus), text, color);
                return;
            }
            statusLabel.Text = text;
            statusLabel.ForeColor = color;
            tray.Text = "Taskbar Remote - " + text;
        }

        private void LoadConfig()
        {
            try
            {
                if (File.Exists(configPath))
                {
                    foreach (var l in File.ReadAllLines(configPath))
                    {
                        if (l.StartsWith("ip=")) ipBox.Text = l.Substring(3).Trim();
                        else if (l.StartsWith("token=")) tokenBox.Text = l.Substring(6).Trim();
                    }
                }
            }
            catch { }
        }

        private void SaveConfig()
        {
            try
            {
                var dir = Path.GetDirectoryName(configPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(configPath,
                    "ip=" + ipBox.Text.Trim() + Environment.NewLine +
                    "token=" + tokenBox.Text.Trim() + Environment.NewLine);
            }
            catch { }
        }

        private bool IsStartupEnabled()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
                {
                    if (k == null) return false;
                    return (k.GetValue(RunName) as string) != null;
                }
            }
            catch { return false; }
        }

        private void OnStartupCheck(object sender, EventArgs e)
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return;
                    if (startupCheck.Checked)
                        k.SetValue(RunName, "\"" + Application.ExecutablePath + "\"");
                    else
                        k.DeleteValue(RunName, false);
                }
            }
            catch { }
        }
    }

    static class Setup
    {
        public const string AppName = "Taskbar Remote";
        private const string UninstallKey =
            "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\TaskbarRemote";
        private const string RunKey =
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string RunName = "TaskbarRemoteAgent";

        public static string InstallDir()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "TaskbarRemote");
        }

        public static string InstalledExe()
        {
            return Path.Combine(InstallDir(), "TaskbarRemote.exe");
        }

        public static bool IsInstalled()
        {
            return string.Equals(Application.ExecutablePath, InstalledExe(),
                StringComparison.OrdinalIgnoreCase);
        }

        private static string StartMenuLnk()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Programs),
                "Taskbar Remote.lnk");
        }

        public static void Install()
        {
            var dir = InstallDir();
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            var dest = InstalledExe();
            var src = Application.ExecutablePath;
            if (!string.Equals(src, dest, StringComparison.OrdinalIgnoreCase))
                File.Copy(src, dest, true);

            CreateShortcut(StartMenuLnk(), dest);

            using (var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                k.SetValue("DisplayName", AppName);
                k.SetValue("DisplayVersion", "1.0.0");
                k.SetValue("Publisher", "Taskbar Remote");
                k.SetValue("DisplayIcon", dest);
                k.SetValue("UninstallString", "\"" + dest + "\" --uninstall");
                k.SetValue("InstallLocation", dir);
                k.SetValue("NoModify", 1, Microsoft.Win32.RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, Microsoft.Win32.RegistryValueKind.DWord);
            }

            using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (k != null) k.SetValue(RunName, "\"" + dest + "\"");
            }
        }

        public static void LaunchInstalled()
        {
            try { Process.Start(InstalledExe()); } catch { }
        }

        private static void CreateShortcut(string lnkPath, string targetExe)
        {
            try
            {
                var t = Type.GetTypeFromProgID("WScript.Shell");
                var shell = Activator.CreateInstance(t);
                var sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod,
                    null, shell, new object[] { lnkPath });
                var st = sc.GetType();
                st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc,
                    new object[] { targetExe });
                st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc,
                    new object[] { Path.GetDirectoryName(targetExe) });
                st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc,
                    new object[] { targetExe + ",0" });
                st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
            }
            catch { }
        }

        public static void Uninstall()
        {
            if (MessageBox.Show("Remove Taskbar Remote from this PC?", AppName,
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                return;

            try
            {
                var me = Process.GetCurrentProcess().Id;
                foreach (var p in Process.GetProcessesByName("TaskbarRemote"))
                    try { if (p.Id != me) p.Kill(); } catch { }
                foreach (var p in Process.GetProcessesByName("taskbar-agent"))
                    try { p.Kill(); } catch { }
            }
            catch { }

            try { if (File.Exists(StartMenuLnk())) File.Delete(StartMenuLnk()); } catch { }
            try
            {
                var desk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    "Taskbar Remote.lnk");
                if (File.Exists(desk)) File.Delete(desk);
            }
            catch { }

            try { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
                    if (k != null) k.DeleteValue(RunName, false);
            }
            catch { }

            try
            {
                var d = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "TaskbarRemote");
                if (Directory.Exists(d)) Directory.Delete(d, true);
            }
            catch { }
            try
            {
                var d = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "TaskbarRemote");
                if (Directory.Exists(d)) Directory.Delete(d, true);
            }
            catch { }

            try
            {
                var exe = Application.ExecutablePath;
                var dir = Path.GetDirectoryName(exe);
                var psi = new ProcessStartInfo();
                psi.FileName = "cmd.exe";
                psi.Arguments = "/c ping 127.0.0.1 -n 3 >nul & del \"" + exe +
                    "\" & rmdir \"" + dir + "\"";
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.CreateNoWindow = true;
                Process.Start(psi);
            }
            catch { }

            MessageBox.Show("Taskbar Remote has been removed.", AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }
}
