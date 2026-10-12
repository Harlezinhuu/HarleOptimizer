// Harle Optimizer - executavel que carrega o script embutido dentro do PowerShell do Windows
// e oferece ao script o que ele nao alcanca sozinho: janela em foco e o perfil do driver NVIDIA.
using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("Harle Optimizer")]
[assembly: AssemblyProduct("Harle Optimizer")]
[assembly: AssemblyDescription("Otimizador de Windows para jogos")]
[assembly: AssemblyCompany("Harle")]
[assembly: AssemblyCopyright("Uso pessoal")]
[assembly: AssemblyVersion("3.6.1.0")]
[assembly: AssemblyFileVersion("3.6.1.0")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.6.1", FrameworkDisplayName = ".NET Framework 4.6.1")]

namespace Harle
{
    /// <summary>Janela em foco, para o modo partida reconhecer o jogo.</summary>
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFO info);

        [DllImport("ntdll.dll")] private static extern int NtSetTimerResolution(uint desired, [MarshalAs(UnmanagedType.U1)] bool set, out uint current);
        [DllImport("ntdll.dll")] private static extern int NtQueryTimerResolution(out uint minimum, out uint maximum, out uint current);

        /// <summary>Resolucao atual do relogio do Windows, em milissegundos (0 se nao deu para ler).</summary>
        public static double TimerResolutionMs()
        {
            try { uint min, max, cur; return NtQueryTimerResolution(out min, out max, out cur) == 0 ? cur / 10000.0 : 0; }
            catch { return 0; }
        }

        /// <summary>
        /// Ajudante do timer: pede 0,5 ms ao Windows e fica parado, sem janela, ate a sessao acabar.
        /// Sem janela porque o Windows 11 ignora o pedido de processos com janela escondida atras do jogo.
        /// </summary>
        internal static int RunTimerHelper()
        {
            bool created;
            using (Mutex one = new Mutex(true, "HarleTimerResolution", out created))
            {
                if (!created) return 0;
                uint cur;
                NtSetTimerResolution(5000, true, out cur);   // 5000 x 100 ns = 0,5 ms
                Thread.Sleep(Timeout.Infinite);
            }
            return 0;
        }

        /// <summary>PID do programa em foco se a janela dele cobre o monitor inteiro; senao 0.</summary>
        public static int FullscreenForegroundPid()
        {
            try
            {
                IntPtr h = GetForegroundWindow();
                if (h == IntPtr.Zero) return 0;
                RECT r;
                if (!GetWindowRect(h, out r)) return 0;
                MONITORINFO mi = new MONITORINFO();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (!GetMonitorInfoW(MonitorFromWindow(h, 2), ref mi)) return 0;
                if (r.Left > mi.rcMonitor.Left || r.Top > mi.rcMonitor.Top || r.Right < mi.rcMonitor.Right || r.Bottom < mi.rcMonitor.Bottom) return 0;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                return (int)pid;
            }
            catch { return 0; }
        }

        /// <summary>PID do programa em foco, em tela cheia ou nao; 0 se nao deu para ler.</summary>
        public static int ForegroundPid()
        {
            try
            {
                IntPtr h = GetForegroundWindow();
                if (h == IntPtr.Zero) return 0;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                return (int)pid;
            }
            catch { return 0; }
        }

        // ----- Overlay: janela por cima do jogo, que nao recebe clique nem foco -----
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] private static extern int SetWindowLong(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        /// <summary>Deixa a janela atravessavel pelo mouse, sem foco e fora do Alt+Tab.</summary>
        public static bool MakeOverlay(IntPtr hwnd)
        {
            try
            {
                const int exStyle = -20;
                int ex = GetWindowLong(hwnd, exStyle);
                // WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
                SetWindowLong(hwnd, exStyle, ex | 0x00080000 | 0x00000020 | 0x00000080 | 0x08000000);
                return true;
            }
            catch { return false; }
        }

        /// <summary>Canto do retangulo de fora onde cabe uma janela de w x h, com margem. Cantos: 0 sup. esq., 1 sup. dir., 2 inf. esq., 3 inf. dir.</summary>
        public static int[] CornerPoint(int left, int top, int right, int bottom, int w, int h, int corner, int margin)
        {
            int x = (corner == 1 || corner == 3) ? right - w - margin : left + margin;
            int y = (corner == 2 || corner == 3) ? bottom - h - margin : top + margin;
            return new int[] { x, y };
        }

        /// <summary>Leva a janela para um canto do monitor onde esta o programa em foco e a mantem por cima de tudo, sem tirar o foco do jogo.</summary>
        public static bool PlaceOverlay(IntPtr hwnd, int corner, int margin)
        {
            try
            {
                RECT me;
                if (!GetWindowRect(hwnd, out me)) return false;
                IntPtr fg = GetForegroundWindow();
                MONITORINFO mi = new MONITORINFO();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                // 1 = monitor principal quando nao ha janela em foco
                if (!GetMonitorInfoW(MonitorFromWindow(fg, 1), ref mi)) return false;
                int[] p = CornerPoint(mi.rcMonitor.Left, mi.rcMonitor.Top, mi.rcMonitor.Right, mi.rcMonitor.Bottom, me.Right - me.Left, me.Bottom - me.Top, corner, margin);
                // HWND_TOPMOST; SWP_NOSIZE | SWP_NOACTIVATE
                return SetWindowPos(hwnd, new IntPtr(-1), p[0], p[1], 0, 0, 0x0001 | 0x0010);
            }
            catch { return false; }
        }

        // ----- Processo filho que morre junto com o Harle (o PresentMon do overlay) -----
        [StructLayout(LayoutKind.Sequential)]
        private struct JobBasicLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct JobExtendedLimits
        {
            public JobBasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JobExtendedLimits info, uint length);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        private static IntPtr job = IntPtr.Zero;

        /// <summary>Amarra o processo ao Harle: se o Harle fechar ou travar, o Windows encerra o processo tambem.</summary>
        public static bool KillWithParent(IntPtr process)
        {
            try
            {
                if (job == IntPtr.Zero)
                {
                    IntPtr j = CreateJobObjectW(IntPtr.Zero, null);
                    if (j == IntPtr.Zero) return false;
                    JobExtendedLimits info = new JobExtendedLimits();
                    info.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    // 9 = JobObjectExtendedLimitInformation
                    if (!SetInformationJobObject(j, 9, ref info, (uint)Marshal.SizeOf(typeof(JobExtendedLimits)))) return false;
                    job = j;
                }
                return AssignProcessToJobObject(job, process);
            }
            catch { return false; }
        }
    }

    /// <summary>
    /// FPS ao vivo para o overlay: le as linhas CSV que o PresentMon escreve na saida padrao (uma por quadro)
    /// e guarda o ultimo segundo de cada programa. Nada e injetado no jogo.
    /// </summary>
    public static class Fps
    {
        private sealed class Track
        {
            public string Name = "";
            public int[] Tick = new int[2048];
            public float[] Ms = new float[2048];
            public int Head, Count;
        }

        private static readonly object gate = new object();
        private static readonly System.Collections.Generic.Dictionary<int, Track> tracks = new System.Collections.Generic.Dictionary<int, Track>();
        private static int generation, lines, colApp = -1, colPid = -1, colMs = -1, columns;
        private static bool alive;

        /// <summary>Nomes de programa (com .exe) que nao contam como jogo.</summary>
        public static string[] Ignore = new string[0];

        public static bool Alive { get { return alive; } }
        /// <summary>Linhas de quadro lidas desde o Start; 0 depois de alguns segundos = o PresentMon nao esta entregando nada.</summary>
        public static int Lines { get { return lines; } }

        public static void Start(TextReader reader)
        {
            int gen;
            lock (gate) { Reset(); gen = ++generation; alive = true; }
            Thread t = new Thread(delegate () { Pump(reader, gen); });
            t.IsBackground = true;
            t.Name = "HarleFps";
            t.Start();
        }

        public static void Stop()
        {
            lock (gate) { generation++; alive = false; Reset(); }
        }

        private static void Reset()
        {
            tracks.Clear();
            lines = 0; columns = 0; colApp = colPid = colMs = -1;
        }

        private static void Pump(TextReader reader, int gen)
        {
            try
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (gen != generation) return;
                    Feed(line, Environment.TickCount);
                }
            }
            catch { }
            finally { lock (gate) { if (gen == generation) alive = false; } }
        }

        /// <summary>Uma linha do CSV. A primeira que comeca com "Application" e o cabecalho e diz onde esta cada coluna.</summary>
        public static void Feed(string line, int tick)
        {
            if (string.IsNullOrEmpty(line)) return;
            string[] f = line.Split(',');
            lock (gate)
            {
                if (colMs < 0)
                {
                    if (!line.StartsWith("Application", StringComparison.OrdinalIgnoreCase)) return;
                    for (int i = 0; i < f.Length; i++)
                    {
                        string c = f[i].Trim();
                        if (string.Equals(c, "Application", StringComparison.OrdinalIgnoreCase)) colApp = i;
                        else if (string.Equals(c, "ProcessID", StringComparison.OrdinalIgnoreCase)) colPid = i;
                        else if (colMs < 0 && (string.Equals(c, "MsBetweenPresents", StringComparison.OrdinalIgnoreCase) || string.Equals(c, "FrameTime", StringComparison.OrdinalIgnoreCase))) colMs = i;
                    }
                    if (colApp < 0 || colPid < 0) colMs = -1;
                    columns = f.Length;
                    return;
                }
                if (f.Length != columns) return;
                int pid;
                float ms;
                if (!int.TryParse(f[colPid], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out pid)) return;
                if (!float.TryParse(f[colMs], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out ms)) return;
                if (!(ms > 0) || ms > 10000) return;
                Track t;
                if (!tracks.TryGetValue(pid, out t)) { t = new Track(); tracks[pid] = t; }
                t.Name = f[colApp];
                t.Tick[t.Head] = tick;
                t.Ms[t.Head] = ms;
                t.Head = (t.Head + 1) % t.Tick.Length;
                if (t.Count < t.Tick.Length) t.Count++;
                lines++;
            }
        }

        private static bool Ignored(string name)
        {
            string[] list = Ignore;
            if (list == null) return false;
            foreach (string s in list) if (string.Equals(s, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // FPS do ultimo segundo: quadros / soma dos tempos entre eles. Devolve tambem quantos quadros entraram na conta.
        private static double Rate(Track t, int now, out int frames)
        {
            double sum = 0;
            frames = 0;
            for (int i = 0; i < t.Count; i++)
            {
                int k = (t.Head - 1 - i + t.Tick.Length * 2) % t.Tick.Length;
                if (unchecked(now - t.Tick[k]) > 1000) break;
                sum += t.Ms[k];
                frames++;
            }
            return (frames >= 2 && sum > 0) ? 1000.0 * frames / sum : -1;
        }

        /// <summary>{ FPS, nome do programa }: o programa em foco se ele estiver desenhando; senao o que mais desenhou no ultimo segundo. FPS -1 = nada.</summary>
        public static object[] Read(int foregroundPid) { return Read(foregroundPid, Environment.TickCount); }

        public static object[] Read(int foregroundPid, int now)
        {
            lock (gate)
            {
                Track t;
                int n;
                if (tracks.TryGetValue(foregroundPid, out t) && !Ignored(t.Name))
                {
                    double fps = Rate(t, now, out n);
                    if (fps > 0) return new object[] { fps, t.Name };
                }
                double best = -1;
                int bestFrames = 0;
                string bestName = "";
                foreach (Track c in tracks.Values)
                {
                    if (Ignored(c.Name)) continue;
                    double fps = Rate(c, now, out n);
                    if (fps > 0 && n > bestFrames) { best = fps; bestFrames = n; bestName = c.Name; }
                }
                return new object[] { best, bestName };
            }
        }
    }

    /// <summary>
    /// Perfil global do driver NVIDIA pela NVAPI (a mesma API do Painel de Controle).
    /// IDs de funcao e formato da estrutura conferidos em nvapi_interface.h e nvapi.h (github.com/NVIDIA/nvapi).
    /// </summary>
    public static class Nvidia
    {
        // NVDRS_SETTING_V1 com #pragma pack(4): 12320 bytes.
        private const int StructSize = 12320;
        private const int StructVersion = StructSize | (1 << 16);
        private const int OffSettingId = 4100;   // depois de version (4) + settingName (2048 * 2)
        private const int OffSettingType = 4104; // 0 = NVDRS_DWORD_TYPE
        private const int OffIsPredefined = 4112;
        private const int OffCurrentValue = 8220; // depois da uniao de valor predefinido (4100)

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryW(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, BestFitMapping = false)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr QueryFn(uint id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int InitFn();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CreateFn(out IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SessionFn(IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ProfileFn(IntPtr session, out IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SetFn(IntPtr session, IntPtr profile, IntPtr setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int GetFn(IntPtr session, IntPtr profile, uint id, IntPtr setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ByIdFn(IntPtr session, IntPtr profile, uint id);

        private delegate int Work(IntPtr session, IntPtr profile);

        private static bool tried;
        private static QueryFn query;
        public static string LastError = "";

        private static Delegate Fn(uint id, Type type)
        {
            IntPtr p = query(id);
            if (p == IntPtr.Zero) throw new EntryPointNotFoundException("NVAPI 0x" + id.ToString("X8"));
            return Marshal.GetDelegateForFunctionPointer(p, type);
        }

        private static bool Init()
        {
            if (tried) return query != null;
            tried = true;
            try
            {
                IntPtr lib = LoadLibraryW(IntPtr.Size == 8 ? "nvapi64.dll" : "nvapi.dll");
                if (lib == IntPtr.Zero) { LastError = "nvapi nao encontrada"; return false; }
                IntPtr qi = GetProcAddress(lib, "nvapi_QueryInterface");
                if (qi == IntPtr.Zero) { LastError = "nvapi_QueryInterface nao encontrada"; return false; }
                query = (QueryFn)Marshal.GetDelegateForFunctionPointer(qi, typeof(QueryFn));
                int st = ((InitFn)Fn(0x0150E828, typeof(InitFn)))();   // NvAPI_Initialize
                if (st != 0) { LastError = "NvAPI_Initialize = " + st; query = null; return false; }
                return true;
            }
            catch (Exception e) { LastError = e.Message; query = null; return false; }
        }

        /// <summary>Ha driver NVIDIA com NVAPI neste PC?</summary>
        public static bool Available() { return Init(); }

        private static int Session(Work work, bool save)
        {
            if (!Init()) return -1;
            try
            {
                IntPtr session;
                int st = ((CreateFn)Fn(0x0694D52E, typeof(CreateFn)))(out session);       // NvAPI_DRS_CreateSession
                if (st != 0) return st;
                try
                {
                    st = ((SessionFn)Fn(0x375DBD6B, typeof(SessionFn)))(session);           // NvAPI_DRS_LoadSettings
                    if (st != 0) return st;
                    IntPtr profile;
                    st = ((ProfileFn)Fn(0xDA8466A0, typeof(ProfileFn)))(session, out profile); // NvAPI_DRS_GetBaseProfile
                    if (st != 0) return st;
                    st = work(session, profile);
                    if (st == 0 && save) st = ((SessionFn)Fn(0xFCBC7E14, typeof(SessionFn)))(session); // NvAPI_DRS_SaveSettings
                    return st;
                }
                finally { ((SessionFn)Fn(0xDAD9CFF8, typeof(SessionFn)))(session); }        // NvAPI_DRS_DestroySession
            }
            catch (Exception e) { LastError = e.Message; return -2; }
        }

        private static IntPtr NewSetting()
        {
            IntPtr buf = Marshal.AllocHGlobal(StructSize);
            for (int i = 0; i < StructSize; i += 4) Marshal.WriteInt32(buf, i, 0);
            Marshal.WriteInt32(buf, 0, StructVersion);
            return buf;
        }

        /// <summary>Le um ajuste do perfil global. Devolve { codigo, valor, 1 se e o padrao do driver }.</summary>
        public static long[] Read(uint id)
        {
            long value = 0, predefined = 0;
            int st = Session(delegate(IntPtr s, IntPtr p)
            {
                IntPtr buf = NewSetting();
                try
                {
                    int r = ((GetFn)Fn(0x73BF8338, typeof(GetFn)))(s, p, id, buf);          // NvAPI_DRS_GetSetting
                    if (r == 0)
                    {
                        value = (uint)Marshal.ReadInt32(buf, OffCurrentValue);
                        predefined = Marshal.ReadInt32(buf, OffIsPredefined) != 0 ? 1 : 0;
                    }
                    return r;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }, false);
            return new long[] { st, value, predefined };
        }

        /// <summary>Grava um ajuste DWORD no perfil global. Devolve 0 se deu certo.</summary>
        public static int Write(uint id, uint value)
        {
            return Session(delegate(IntPtr s, IntPtr p)
            {
                IntPtr buf = NewSetting();
                try
                {
                    Marshal.WriteInt32(buf, OffSettingId, unchecked((int)id));
                    Marshal.WriteInt32(buf, OffSettingType, 0);
                    Marshal.WriteInt32(buf, OffCurrentValue, unchecked((int)value));
                    return ((SetFn)Fn(0x577DD202, typeof(SetFn)))(s, p, buf);               // NvAPI_DRS_SetSetting
                }
                finally { Marshal.FreeHGlobal(buf); }
            }, true);
        }

        // ----- Deslocamento de clock (overclock) -----
        // Estrutura NV_GPU_PERF_PSTATES20_INFO conferida em nvapi.h (pack 8, so campos de 4 bytes):
        // cabecalho 20 bytes; cada P-state 456; cada clock 44 (dominio 0, tipo 4, flags 8, delta 12, min 16, max 20).
        // V1 = 7316 bytes, V2/V3 = 7416. NvAPI_GPU_SetPstates20 nao esta no SDK publico: o ID 0x0F4DAE6B
        // vem de projetos abertos (NvAPIWrapper) que usam a mesma chamada.
        private const int PsHeader = 20, PsState = 456, PsClock = 44;
        private static readonly int[] PsSizes = { 7316, 7416, 7416 };
        private static readonly int[] PsVersions = { 7316 | (1 << 16), 7416 | (2 << 16), 7416 | (3 << 16) };
        private static int psIndex = -1;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int EnumGpusFn([In, Out] IntPtr[] handles, out uint count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int PstatesFn(IntPtr gpu, IntPtr info);

        private static IntPtr FirstGpu()
        {
            IntPtr[] handles = new IntPtr[64];
            uint count;
            int st = ((EnumGpusFn)Fn(0xE5AC921F, typeof(EnumGpusFn)))(handles, out count);   // NvAPI_EnumPhysicalGPUs
            return (st == 0 && count > 0) ? handles[0] : IntPtr.Zero;
        }

        private static IntPtr NewPstates(int index)
        {
            IntPtr buf = Marshal.AllocHGlobal(PsSizes[index]);
            for (int i = 0; i < PsSizes[index]; i += 4) Marshal.WriteInt32(buf, i, 0);
            Marshal.WriteInt32(buf, 0, PsVersions[index]);
            return buf;
        }

        /// <summary>
        /// Le os deslocamentos de clock do P-state de desempenho.
        /// Devolve { codigo, nucleo editavel, nucleo kHz, min, max, memoria editavel, memoria kHz, min, max }.
        /// </summary>
        public static long[] OcRead()
        {
            long[] r = new long[9];
            r[0] = -1;
            if (!Init()) return r;
            try
            {
                IntPtr gpu = FirstGpu();
                if (gpu == IntPtr.Zero) { r[0] = -6; return r; }
                PstatesFn get = (PstatesFn)Fn(0x6FF81213, typeof(PstatesFn));               // NvAPI_GPU_GetPstates20
                for (int v = (psIndex >= 0 ? psIndex : 0); v < PsSizes.Length; v++)
                {
                    IntPtr buf = NewPstates(v);
                    try
                    {
                        int st = get(gpu, buf);
                        r[0] = st;
                        if (st != 0) { if (psIndex >= 0) break; continue; }
                        psIndex = v;
                        int states = Marshal.ReadInt32(buf, 8), clocks = Marshal.ReadInt32(buf, 12);
                        int p = 0;
                        for (int i = 0; i < states && i < 16; i++) if (Marshal.ReadInt32(buf, PsHeader + i * PsState) == 0) { p = i; break; }
                        int first = PsHeader + p * PsState + 8;
                        for (int c = 0; c < clocks && c < 8; c++)
                        {
                            int o = first + c * PsClock;
                            int domain = Marshal.ReadInt32(buf, o);
                            int slot = domain == 0 ? 1 : (domain == 4 ? 5 : -1);
                            if (slot < 0) continue;
                            r[slot] = Marshal.ReadInt32(buf, o + 8) & 1;
                            r[slot + 1] = Marshal.ReadInt32(buf, o + 12);
                            r[slot + 2] = Marshal.ReadInt32(buf, o + 16);
                            r[slot + 3] = Marshal.ReadInt32(buf, o + 20);
                        }
                        return r;
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
                return r;
            }
            catch (Exception e) { LastError = e.Message; r[0] = -2; return r; }
        }

        /// <summary>
        /// Grava o deslocamento de um clock (dominio 0 = nucleo, 4 = memoria), em kHz.
        /// Recusa o que estiver fora da faixa que o proprio driver informa. Devolve 0 se deu certo.
        /// </summary>
        public static int OcWrite(int domain, int deltaKHz)
        {
            if (domain != 0 && domain != 4) return -5;
            long[] cur = OcRead();
            if (cur[0] != 0 || psIndex < 0) return (int)cur[0] == 0 ? -1 : (int)cur[0];
            int slot = domain == 0 ? 1 : 5;
            if (cur[slot] == 0) return -3;                                       // o driver nao deixa editar
            if (deltaKHz < cur[slot + 2] || deltaKHz > cur[slot + 3]) return -4; // fora da faixa do driver
            try
            {
                IntPtr gpu = FirstGpu();
                if (gpu == IntPtr.Zero) return -6;
                IntPtr buf = NewPstates(psIndex);
                try
                {
                    Marshal.WriteInt32(buf, 8, 1);                       // numPstates
                    Marshal.WriteInt32(buf, 12, 1);                      // numClocks
                    Marshal.WriteInt32(buf, PsHeader, 0);                // pstateId = P0
                    Marshal.WriteInt32(buf, PsHeader + 8, domain);       // clocks[0].domainId
                    Marshal.WriteInt32(buf, PsHeader + 8 + 12, deltaKHz);// clocks[0].freqDelta_kHz.value
                    return ((PstatesFn)Fn(0x0F4DAE6B, typeof(PstatesFn)))(gpu, buf);        // NvAPI_GPU_SetPstates20
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch (Exception e) { LastError = e.Message; return -2; }
        }

        /// <summary>Devolve um ajuste do perfil global ao padrao do driver. Devolve 0 se deu certo.</summary>
        public static int Reset(uint id)
        {
            return Session(delegate(IntPtr s, IntPtr p)
            {
                return ((ByIdFn)Fn(0x53F0381E, typeof(ByIdFn)))(s, p, id);                  // NvAPI_DRS_RestoreProfileDefaultSetting
            }, true);
        }
    }

    /// <summary>
    /// Ajustes globais do driver Radeon pela AMD Display Library (atiadlxx.dll).
    /// Assinaturas e estruturas conferidas em adl_sdk.h, adl_structures.h e na documentacao da ADL
    /// (github.com/GPUOpen-LibrariesAndSDKs/display-library).
    /// </summary>
    public static class Amd
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct DelagSettings { public int Hotkey, GlobalEnable, GlobalLimitFPS, MinLimit, MaxLimit, Step; }
        [StructLayout(LayoutKind.Sequential)]
        private struct DelagReason { public int HotkeyChanged, GlobalEnableChanged, GlobalLimitFPSChanged; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ErrorReason { public int Boost, Delag, Chill, ProVsr; }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate IntPtr MallocFn(int size);

        private const string Dll = "atiadlxx.dll";
        [DllImport(Dll, EntryPoint = "ADL2_Main_Control_Create")] private static extern int Create(MallocFn callback, int enumConnectedAdapters, out IntPtr context);
        [DllImport(Dll, EntryPoint = "ADL2_Main_Control_Destroy")] private static extern int Destroy(IntPtr context);
        [DllImport(Dll, EntryPoint = "ADL2_Adapter_Primary_Get")] private static extern int PrimaryGet(IntPtr context, out int adapterIndex);
        [DllImport(Dll, EntryPoint = "ADL2_DELAG_Settings_Get")] private static extern int DelagGet(IntPtr context, int adapterIndex, out DelagSettings settings);
        [DllImport(Dll, EntryPoint = "ADL2_DELAG_Settings_Set")] private static extern int DelagSet(IntPtr context, int adapterIndex, DelagSettings settings, DelagReason reason, out ErrorReason error);
        [DllImport(Dll, EntryPoint = "ADL2_Chill_Settings_Get")] private static extern int ChillGet(IntPtr context, int adapterIndex, out int enabled);
        [DllImport(Dll, EntryPoint = "ADL2_Chill_Settings_Set")] private static extern int ChillSet(IntPtr context, int adapterIndex, int enabled);

        private static readonly MallocFn Malloc = delegate(int size) { return Marshal.AllocHGlobal(size); };
        private delegate int Work(IntPtr context, int adapter);
        public static string LastError = "";

        private static int Session(Work work)
        {
            try
            {
                IntPtr ctx;
                int st = Create(Malloc, 1, out ctx);
                if (st != 0) return st;
                try
                {
                    int adapter;
                    if (PrimaryGet(ctx, out adapter) != 0) adapter = 0;
                    return work(ctx, adapter);
                }
                finally { Destroy(ctx); }
            }
            catch (Exception e) { LastError = e.Message; return -100; }
        }

        /// <summary>Le o estado atual. Devolve { codigo, Anti-Lag (0/1), Chill (0/1) }.</summary>
        public static int[] Read()
        {
            int lag = 0, chill = 0;
            int st = Session(delegate(IntPtr ctx, int adapter)
            {
                DelagSettings s;
                int r = DelagGet(ctx, adapter, out s);
                if (r != 0) return r;
                lag = s.GlobalEnable != 0 ? 1 : 0;
                int c;
                try { if (ChillGet(ctx, adapter, out c) == 0) chill = c != 0 ? 1 : 0; } catch (EntryPointNotFoundException) { }
                return 0;
            });
            return new int[] { st, lag, chill };
        }

        // ----- Sensores (ADL2_New_QueryPMLogData_Get): saida de 4 + 256 x 8 bytes, um par {suportado, valor} por sensor -----
        [DllImport(Dll, EntryPoint = "ADL2_New_QueryPMLogData_Get")] private static extern int PmLogGet(IntPtr context, int adapterIndex, IntPtr output);
        private static IntPtr monitorContext = IntPtr.Zero;
        private static int monitorAdapter;
        private static bool monitorTried;

        /// <summary>{ ok, temperatura C, uso %, VRAM usada MB, VRAM total MB, ventoinha %, consumo W, clock nucleo MHz, clock memoria MHz }; -1 = sem leitura.</summary>
        public static double[] Monitor()
        {
            double[] r = { 0, -1, -1, -1, -1, -1, -1, -1, -1 };
            try
            {
                if (!monitorTried)
                {
                    monitorTried = true;
                    IntPtr ctx;
                    if (Create(Malloc, 1, out ctx) == 0)
                    {
                        monitorContext = ctx;
                        if (PrimaryGet(ctx, out monitorAdapter) != 0) monitorAdapter = 0;
                    }
                }
                if (monitorContext == IntPtr.Zero) return r;
                const int size = 4 + 256 * 8;
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    for (int i = 0; i < size; i += 4) Marshal.WriteInt32(buf, i, 0);
                    if (PmLogGet(monitorContext, monitorAdapter, buf) != 0) return r;
                    r[0] = 1;
                    r[1] = Sensor(buf, 8);    // PMLOG_TEMPERATURE_EDGE
                    r[2] = Sensor(buf, 19);   // PMLOG_INFO_ACTIVITY_GFX
                    r[5] = Sensor(buf, 15);   // PMLOG_FAN_PERCENTAGE
                    r[6] = Sensor(buf, 23);   // PMLOG_ASIC_POWER
                    if (r[6] < 0) r[6] = Sensor(buf, 30);   // PMLOG_GFX_POWER
                    r[7] = Sensor(buf, 1);    // PMLOG_CLK_GFXCLK
                    r[8] = Sensor(buf, 2);    // PMLOG_CLK_MEMCLK
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            catch (Exception e) { LastError = e.Message; }
            return r;
        }

        private static double Sensor(IntPtr buf, int id)
        {
            int o = 4 + id * 8;
            return Marshal.ReadInt32(buf, o) != 0 ? Marshal.ReadInt32(buf, o + 4) : -1;
        }

        /// <summary>Ha driver Radeon com Anti-Lag neste PC?</summary>
        public static bool Available() { return Read()[0] == 0; }

        /// <summary>Liga ou desliga o Anti-Lag e o Chill globais. Devolve 0 se deu certo.</summary>
        public static int Apply(int antiLag, int chill)
        {
            return Session(delegate(IntPtr ctx, int adapter)
            {
                try { ChillSet(ctx, adapter, chill != 0 ? 1 : 0); } catch (EntryPointNotFoundException) { }
                DelagSettings s;
                int r = DelagGet(ctx, adapter, out s);
                if (r != 0) return r;
                s.GlobalEnable = antiLag != 0 ? 1 : 0;
                DelagReason reason = new DelagReason();
                reason.GlobalEnableChanged = 1;
                ErrorReason error;
                return DelagSet(ctx, adapter, s, reason, out error);
            });
        }
    }

    /// <summary>
    /// Leituras ao vivo: placa NVIDIA pela NVML (nvml.dll, que vem com o driver), processador e memoria pelo Windows.
    /// Assinaturas da NVML conferidas em nvml.h (github.com/NVIDIA/go-nvml).
    /// </summary>
    public static class Monitor
    {
        [StructLayout(LayoutKind.Sequential)] private struct NvmlUtilization { public uint Gpu, Memory; }
        [StructLayout(LayoutKind.Sequential)] private struct NvmlMemory { public ulong Total, Free, Used; }

        private const string Nvml = "nvml.dll";
        [DllImport(Nvml, EntryPoint = "nvmlInit_v2")] private static extern int NvmlInit();
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetHandleByIndex_v2")] private static extern int NvmlDevice(uint index, out IntPtr device);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetTemperature")] private static extern int NvmlTemperature(IntPtr device, int sensor, out uint value);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetUtilizationRates")] private static extern int NvmlUtilizationRates(IntPtr device, out NvmlUtilization value);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetMemoryInfo")] private static extern int NvmlMemoryInfo(IntPtr device, out NvmlMemory value);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetFanSpeed")] private static extern int NvmlFanSpeed(IntPtr device, out uint value);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetPowerUsage")] private static extern int NvmlPowerUsage(IntPtr device, out uint milliwatts);
        [DllImport(Nvml, EntryPoint = "nvmlDeviceGetClockInfo")] private static extern int NvmlClockInfo(IntPtr device, int type, out uint mhz);

        private static bool nvTried;
        private static IntPtr nvDevice = IntPtr.Zero;
        public static string LastError = "";

        /// <summary>{ ok, temperatura C, uso %, VRAM usada MB, VRAM total MB, ventoinha %, consumo W, clock nucleo MHz, clock memoria MHz }; -1 = sem leitura.</summary>
        public static double[] Nvidia()
        {
            double[] r = { 0, -1, -1, -1, -1, -1, -1, -1, -1 };
            try
            {
                if (!nvTried)
                {
                    nvTried = true;
                    IntPtr dev;
                    if (NvmlInit() == 0 && NvmlDevice(0, out dev) == 0) nvDevice = dev;
                }
                if (nvDevice == IntPtr.Zero) return r;
                r[0] = 1;
                uint v;
                if (NvmlTemperature(nvDevice, 0, out v) == 0) r[1] = v;
                NvmlUtilization u;
                if (NvmlUtilizationRates(nvDevice, out u) == 0) r[2] = u.Gpu;
                NvmlMemory m;
                if (NvmlMemoryInfo(nvDevice, out m) == 0) { r[3] = m.Used / 1048576.0; r[4] = m.Total / 1048576.0; }
                if (NvmlFanSpeed(nvDevice, out v) == 0) r[5] = v;
                if (NvmlPowerUsage(nvDevice, out v) == 0) r[6] = v / 1000.0;
                if (NvmlClockInfo(nvDevice, 0, out v) == 0) r[7] = v;
                if (NvmlClockInfo(nvDevice, 2, out v) == 0) r[8] = v;
            }
            catch (Exception e) { LastError = e.Message; }
            return r;
        }

        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        private static long lastIdle, lastTotal;

        /// <summary>Uso do processador desde a chamada anterior, em % (-1 na primeira ou se falhar).</summary>
        public static double CpuPercent()
        {
            try
            {
                long idle, kernel, user;
                if (!GetSystemTimes(out idle, out kernel, out user)) return -1;
                long total = kernel + user;   // o tempo de kernel ja inclui o ocioso
                long dTotal = total - lastTotal, dIdle = idle - lastIdle;
                bool first = lastTotal == 0;
                lastTotal = total; lastIdle = idle;
                if (first || dTotal <= 0) return -1;
                return Math.Max(0, Math.Min(100, 100.0 * (dTotal - dIdle) / dTotal));
            }
            catch { return -1; }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatusEx
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

        /// <summary>{ RAM usada MB, RAM total MB } (-1 se falhar).</summary>
        public static double[] Memory()
        {
            try
            {
                MemoryStatusEx s = new MemoryStatusEx();
                s.Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
                if (!GlobalMemoryStatusEx(ref s)) return new double[] { -1, -1 };
                return new double[] { (s.TotalPhys - s.AvailPhys) / 1048576.0, s.TotalPhys / 1048576.0 };
            }
            catch { return new double[] { -1, -1 }; }
        }
    }

    // Limpeza de memoria no estilo do Mem Reduct, feita do zero pelas chamadas do proprio Windows:
    // listas de memoria (NtQuerySystemInformation/NtSetSystemInformation, classe 80) e working set dos programas.
    public static class Memory
    {
        [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int infoClass, IntPtr info, int length, out int returned);
        [DllImport("ntdll.dll")] private static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
        [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValueW(string system, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivilege state, int length, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct TokenPrivilege { public int Count; public long Luid; public int Attributes; }

        private const int SystemMemoryListInformation = 80;
        public const int EmptyWorkingSets = 2, FlushModifiedList = 3, PurgeStandbyList = 4, PurgeLowPriorityStandbyList = 5;
        public static string LastError = "";
        private static bool privileged;

        private static bool Privilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) return false;
            try
            {
                long luid;
                if (!LookupPrivilegeValueW(null, name, out luid)) return false;
                TokenPrivilege tp = new TokenPrivilege { Count = 1, Luid = luid, Attributes = 2 };
                if (!AdjustTokenPrivileges(token, false, ref tp, Marshal.SizeOf(typeof(TokenPrivilege)), IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            }
            finally { CloseHandle(token); }
        }

        // Em MB: [0] zerada, [1] livre, [2] modificada, [3] modificada sem gravar, [4] com defeito,
        // [5] em espera (cache) total, [6] em espera de baixa prioridade (0 a 2). -1 = sem leitura.
        public static double[] Lists()
        {
            double[] r = new double[] { -1, -1, -1, -1, -1, -1, -1 };
            // A consulta das listas pede o privilegio de perfil (o Harle roda como administrador, que o tem).
            if (!privileged) { try { Privilege("SeProfileSingleProcessPrivilege"); } catch { } privileged = true; }
            int n = IntPtr.Size;
            int size = (5 + 8 + 8 + 1) * n;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                int got;
                int st = NtQuerySystemInformation(SystemMemoryListInformation, buf, size, out got);
                if (st != 0) { LastError = "consulta: 0x" + st.ToString("X8"); return r; }
                Func<int, double> page = i => (n == 8 ? (double)Marshal.ReadInt64(buf, i * n) : (double)(uint)Marshal.ReadInt32(buf, i * n)) * 4096.0 / 1048576.0;
                for (int i = 0; i < 5; i++) r[i] = page(i);
                double standby = 0, low = 0;
                for (int p = 0; p < 8; p++) { double v = page(5 + p); standby += v; if (p <= 2) low += v; }
                r[5] = standby; r[6] = low;
                return r;
            }
            catch (Exception e) { LastError = e.Message; return r; }
            finally { Marshal.FreeHGlobal(buf); }
        }

        // Roda um comando nas listas de memoria. Devolve o NTSTATUS (0 = ok).
        public static int Command(int command)
        {
            try
            {
                Privilege("SeProfileSingleProcessPrivilege");
                Privilege("SeIncreaseQuotaPrivilege");
                int c = command;
                int st = NtSetSystemInformation(SystemMemoryListInformation, ref c, 4);
                if (st != 0) LastError = "comando " + command + ": 0x" + st.ToString("X8");
                return st;
            }
            catch (Exception e) { LastError = e.Message; return -1; }
        }
    }

    // Leitura do S.M.A.R.T. dos discos, como o CrystalDiskInfo: NVMe pela pagina de saude (log 02h)
    // e SATA pelo comando SMART READ DATA / READ THRESHOLDS. Precisa de administrador.
    public static class Disk
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(IntPtr device, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);

        private const uint IoctlQueryProperty = 0x002D1400;
        private const uint IoctlSmartRcv = 0x0007C088;
        private const uint IoctlAtaPassThrough = 0x0004D02C;
        public static string LastError = "";

        private static IntPtr Open(int disk)
        {
            string path = "\\\\.\\PhysicalDrive" + disk;
            IntPtr h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == IntPtr.Zero || h == new IntPtr(-1)) h = CreateFileW(path, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == IntPtr.Zero || h == new IntPtr(-1)) { LastError = "abrir: " + Marshal.GetLastWin32Error(); return IntPtr.Zero; }
            return h;
        }

        private static long U64(byte[] b, int at) { return (long)(BitConverter.ToUInt64(b, at) & 0x7FFFFFFFFFFFFFFFUL); }

        // [0] 0 = ok (negativo = erro do Windows), [1] aviso critico, [2] temperatura (C), [3] reserva disponivel %,
        // [4] limite da reserva %, [5] vida usada %, [6] unidades lidas, [7] unidades escritas (1 unidade = 512.000 bytes),
        // [8] comandos de leitura, [9] comandos de escrita, [10] tempo ocupado (min), [11] ciclos de energia,
        // [12] horas ligado, [13] desligamentos inseguros, [14] erros de midia, [15] entradas no log de erros,
        // [16] minutos acima do aviso de temperatura, [17] minutos acima do critico, [18..25] sensores de temperatura (C, 0 = sem)
        public static long[] Nvme(int disk)
        {
            long[] r = new long[26]; r[0] = -1;
            IntPtr h = IntPtr.Zero;
            try
            {
                h = Open(disk);
                if (h == IntPtr.Zero) return r;
                byte[] q = new byte[8 + 40 + 512];
                BitConverter.GetBytes(50).CopyTo(q, 0);  // StorageDeviceProtocolSpecificProperty
                BitConverter.GetBytes(0).CopyTo(q, 4);   // PropertyStandardQuery
                BitConverter.GetBytes(3).CopyTo(q, 8);   // ProtocolTypeNvme
                BitConverter.GetBytes(2).CopyTo(q, 12);  // NVMeDataTypeLogPage
                BitConverter.GetBytes(2).CopyTo(q, 16);  // log de saude (SMART / Health Information)
                BitConverter.GetBytes(0).CopyTo(q, 20);
                BitConverter.GetBytes(40).CopyTo(q, 24); // ProtocolDataOffset
                BitConverter.GetBytes(512).CopyTo(q, 28);// ProtocolDataLength
                byte[] o = new byte[q.Length];
                int got;
                if (!DeviceIoControl(h, IoctlQueryProperty, q, q.Length, o, o.Length, out got, IntPtr.Zero)) { r[0] = -Marshal.GetLastWin32Error(); LastError = "nvme: " + (-r[0]); return r; }
                int off = 8 + BitConverter.ToInt32(o, 8 + 16);
                int len = BitConverter.ToInt32(o, 8 + 20);
                if (len < 216 || off + 216 > o.Length) { r[0] = -2; LastError = "nvme: resposta curta"; return r; }
                byte[] d = new byte[512];
                Array.Copy(o, off, d, 0, Math.Min(512, o.Length - off));
                r[1] = d[0];
                int k = BitConverter.ToUInt16(d, 1);
                r[2] = k > 0 ? k - 273 : -1;
                r[3] = d[3]; r[4] = d[4]; r[5] = d[5];
                for (int i = 0; i < 11; i++) r[6 + i] = U64(d, 32 + 16 * i);
                r[16] = BitConverter.ToUInt32(d, 192);
                r[17] = BitConverter.ToUInt32(d, 196);
                for (int i = 0; i < 8; i++) { int s = BitConverter.ToUInt16(d, 200 + 2 * i); r[18 + i] = s > 0 ? s - 273 : 0; }
                r[0] = 0;
            }
            catch (Exception e) { r[0] = -3; LastError = e.Message; }
            finally { if (h != IntPtr.Zero) CloseHandle(h); }
            return r;
        }

        private static byte[] SmartIoctl(IntPtr h, byte feature)
        {
            byte[] q = new byte[32];
            BitConverter.GetBytes(512).CopyTo(q, 0);
            q[4] = feature; q[5] = 1; q[6] = 1; q[7] = 0x4F; q[8] = 0xC2; q[9] = 0xA0; q[10] = 0xB0;
            byte[] o = new byte[16 + 512];
            int got;
            if (!DeviceIoControl(h, IoctlSmartRcv, q, q.Length, o, o.Length, out got, IntPtr.Zero) || got < 16 + 362) return null;
            byte[] d = new byte[512];
            Array.Copy(o, 16, d, 0, 512);
            return d;
        }

        private static byte[] AtaPassThrough(IntPtr h, byte feature)
        {
            int head = IntPtr.Size == 8 ? 48 : 40;
            byte[] q = new byte[head + 512];
            BitConverter.GetBytes((ushort)head).CopyTo(q, 0);   // Length
            BitConverter.GetBytes((ushort)0x03).CopyTo(q, 2);   // ATA_FLAGS_DRDY_REQUIRED | ATA_FLAGS_DATA_IN
            BitConverter.GetBytes(512).CopyTo(q, 8);            // DataTransferLength
            BitConverter.GetBytes(10).CopyTo(q, 12);            // TimeOutValue (s)
            int tf;
            if (IntPtr.Size == 8) { BitConverter.GetBytes((long)head).CopyTo(q, 24); tf = 32; }
            else { BitConverter.GetBytes(head).CopyTo(q, 20); tf = 24; }
            int c = tf + 8;                                     // CurrentTaskFile
            q[c] = feature; q[c + 1] = 1; q[c + 2] = 1; q[c + 3] = 0x4F; q[c + 4] = 0xC2; q[c + 5] = 0xA0; q[c + 6] = 0xB0;
            byte[] o = new byte[q.Length];
            int got;
            if (!DeviceIoControl(h, IoctlAtaPassThrough, q, q.Length, o, o.Length, out got, IntPtr.Zero)) return null;
            if ((o[c + 6] & 0x01) != 0) return null;            // bit de erro no status
            byte[] d = new byte[512];
            Array.Copy(o, head, d, 0, 512);
            return d;
        }

        // [0] 0 = ok (negativo = sem SMART), [1] quantidade de atributos, depois 6 valores por atributo:
        // id, flags, atual, pior, limite, bruto (48 bits).
        public static long[] Ata(int disk)
        {
            IntPtr h = IntPtr.Zero;
            try
            {
                h = Open(disk);
                if (h == IntPtr.Zero) return new long[] { -1, 0 };
                byte[] v = SmartIoctl(h, 0xD0), t = null;
                if (v != null) t = SmartIoctl(h, 0xD1);
                else { v = AtaPassThrough(h, 0xD0); if (v != null) t = AtaPassThrough(h, 0xD1); }
                if (v == null) { LastError = "smart: " + Marshal.GetLastWin32Error(); return new long[] { -2, 0 }; }
                var list = new System.Collections.Generic.List<long>();
                list.Add(0); list.Add(0);
                int n = 0;
                for (int i = 0; i < 30; i++)
                {
                    int at = 2 + 12 * i;
                    int id = v[at];
                    if (id == 0) continue;
                    long thr = -1;
                    if (t != null) for (int j = 0; j < 30; j++) if (t[2 + 12 * j] == id) { thr = t[3 + 12 * j]; break; }
                    long raw = 0;
                    for (int b = 5; b >= 0; b--) raw = (raw << 8) | v[at + 5 + b];
                    list.Add(id); list.Add(BitConverter.ToUInt16(v, at + 1)); list.Add(v[at + 3]); list.Add(v[at + 4]); list.Add(thr); list.Add(raw);
                    n++;
                }
                list[1] = n;
                return list.ToArray();
            }
            catch (Exception e) { LastError = e.Message; return new long[] { -3, 0 }; }
            finally { if (h != IntPtr.Zero) CloseHandle(h); }
        }
    }

    internal static class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        // ATENCAO: 3.0.0.0 e a versao do PowerShell que vem no Windows, nao a do Harle. Nao mexer.
        private const string Sma = "System.Management.Automation, Version=" + "3.0" + ".0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35";

        private static MethodInfo Find(Type type, string name, int args)
        {
            foreach (MethodInfo m in type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static))
            {
                if (m.Name == name && !m.IsGenericMethod && m.GetParameters().Length == args)
                {
                    if (args == 1 && m.GetParameters()[0].ParameterType != typeof(string)) continue;
                    return m;
                }
            }
            throw new MissingMethodException(type.FullName, name);
        }

        private static void Log(string text)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Harle");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "harle.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  EXE: " + text + Environment.NewLine, Encoding.UTF8);
            }
            catch { }
        }

        [STAThread]
        private static int Main(string[] args)
        {
            string dump = Environment.GetEnvironmentVariable("HARLE_DUMP");
            string line = string.Join(" ", args);
            bool silent = line.IndexOf("/reaplicar", StringComparison.OrdinalIgnoreCase) >= 0;
            if (line.IndexOf("/timer", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                try { return Native.RunTimerHelper(); } catch (Exception e) { Log("timer: " + e.Message); return 1; }
            }
            try
            {
                Environment.SetEnvironmentVariable("HARLE_ARGS", line);
                Environment.SetEnvironmentVariable("HARLE_EXE", typeof(Program).Assembly.Location);
                Environment.SetEnvironmentVariable("HARLE_HOSTED", "1");
                Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");

                string script;
                using (Stream s = typeof(Program).Assembly.GetManifestResourceStream("Harle.ps1"))
                using (StreamReader r = new StreamReader(s, Encoding.UTF8, true))
                {
                    script = r.ReadToEnd();
                }

                Assembly sma = Assembly.Load(Sma);
                Type factory = sma.GetType("System.Management.Automation.Runspaces.RunspaceFactory", true);
                Type rsType = sma.GetType("System.Management.Automation.Runspaces.Runspace", true);
                Type optType = sma.GetType("System.Management.Automation.Runspaces.PSThreadOptions", true);
                Type psType = sma.GetType("System.Management.Automation.PowerShell", true);

                // A janela (WPF) precisa rodar nesta mesma thread STA.
                object rs = Find(factory, "CreateRunspace", 0).Invoke(null, null);
                try { rsType.GetProperty("ApartmentState").SetValue(rs, ApartmentState.STA, null); } catch { }
                rsType.GetProperty("ThreadOptions").SetValue(rs, Enum.Parse(optType, "UseCurrentThread"), null);
                Find(rsType, "Open", 0).Invoke(rs, null);

                object ps = Find(psType, "Create", 0).Invoke(null, null);
                psType.GetProperty("Runspace").SetValue(ps, rs, null);
                Find(psType, "AddScript", 1).Invoke(ps, new object[] { script });
                object output = Find(psType, "Invoke", 0).Invoke(ps, null);

                StringBuilder errors = new StringBuilder();
                object streams = psType.GetProperty("Streams").GetValue(ps, null);
                IEnumerable errorList = (IEnumerable)streams.GetType().GetProperty("Error").GetValue(streams, null);
                foreach (object e in errorList) errors.AppendLine(Convert.ToString(e));
                if (errors.Length > 0) Log("erros do script: " + errors);

                if (!string.IsNullOrEmpty(dump))
                {
                    StringBuilder sb = new StringBuilder();
                    foreach (object o in (IEnumerable)output) sb.AppendLine(Convert.ToString(o));
                    sb.AppendLine("--- erros ---");
                    sb.Append(errors);
                    File.WriteAllText(dump, sb.ToString(), Encoding.UTF8);
                }
                return 0;
            }
            catch (Exception ex)
            {
                Exception e = ex;
                while (e is TargetInvocationException && e.InnerException != null) e = e.InnerException;
                Log("falha ao abrir: " + e);
                if (!string.IsNullOrEmpty(dump))
                {
                    try { File.WriteAllText(dump, "FALHA: " + e, Encoding.UTF8); } catch { }
                }
                else if (!silent)
                {
                    MessageBoxW(IntPtr.Zero, "O Harle n\u00e3o conseguiu abrir.\n\n" + e.Message + "\n\nDetalhes em C:\\ProgramData\\Harle\\harle.log", "Harle Optimizer", 0x10);
                }
                return 1;
            }
        }
    }
}
