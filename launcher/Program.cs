using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace KeepTeamsGreen.Launcher
{
    internal static class Program
    {
        private const string AppName = "KeepTeamsGreen";

        [STAThread]
        private static void Main()
        {
            using (Mutex instanceMutex = new Mutex(false, @"Local\KeepTeamsGreen.SingleInstance"))
            {
                bool ownsMutex;
                try
                {
                    ownsMutex = instanceMutex.WaitOne(0, false);
                }
                catch (AbandonedMutexException)
                {
                    ownsMutex = true;
                }

                if (!ownsMutex)
                {
                    MessageBox.Show(
                        "KeepTeamsGreen e gia in esecuzione nell area di notifica.",
                        AppName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                try
                {
                    RunApplication();
                }
                finally
                {
                    instanceMutex.ReleaseMutex();
                }
            }
        }

        private static void RunApplication()
        {
            try
            {
                Assembly assembly = Assembly.GetExecutingAssembly();
                string script = ReadTextResource(assembly, "script.gui.ps1");
                string assetDirectory = ExtractAssets(assembly);

                Environment.SetEnvironmentVariable("KTG_ASSET_DIR", assetDirectory);
                Environment.SetEnvironmentVariable("KTG_ERROR_SHOWN", "0");

                using (Runspace runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
                {
                    runspace.ApartmentState = System.Threading.ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();

                    TrySetVariable(runspace, "PSScriptRoot", AppDomain.CurrentDomain.BaseDirectory);
                    TrySetVariable(runspace, "PSCommandPath", assembly.Location);

                    using (PowerShell powerShell = PowerShell.Create())
                    {
                        powerShell.Runspace = runspace;
                        powerShell.AddScript(script, false);
                        Runspace previousDefaultRunspace = Runspace.DefaultRunspace;
                        Runspace.DefaultRunspace = runspace;
                        try
                        {
                            powerShell.Invoke();

                            if (powerShell.InvocationStateInfo.State == PSInvocationState.Failed && !WasErrorShown())
                            {
                                ShowPowerShellErrors(powerShell.Streams.Error);
                            }
                        }
                        finally
                        {
                            Runspace.DefaultRunspace = previousDefaultRunspace;
                        }
                    }
                }
            }
            catch (Exception exception)
            {
                if (!WasErrorShown())
                {
                    MessageBox.Show(
                        exception.Message + Environment.NewLine + Environment.NewLine +
                        "Dettagli: %APPDATA%\\KeepTeamsGreen\\last_run.log",
                        AppName + " - Errore di avvio",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
            }
        }

        private static bool WasErrorShown()
        {
            return String.Equals(
                Environment.GetEnvironmentVariable("KTG_ERROR_SHOWN"),
                "1",
                StringComparison.Ordinal);
        }

        private static string ReadTextResource(Assembly assembly, string resourceName)
        {
            using (Stream stream = assembly.GetManifestResourceStream(resourceName))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("Risorsa non trovata: " + resourceName);
                }

                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    return reader.ReadToEnd();
                }
            }
        }

        private static string ExtractAssets(Assembly assembly)
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string assetDirectory = Path.Combine(appData, AppName, "assets");
            Directory.CreateDirectory(assetDirectory);

            string logoPath = Path.Combine(assetDirectory, "logo.png");
            using (Stream source = assembly.GetManifestResourceStream("logo.png"))
            {
                if (source == null)
                {
                    throw new InvalidOperationException("Logo incorporato non trovato.");
                }

                using (FileStream target = new FileStream(logoPath, FileMode.Create, FileAccess.Write, FileShare.Read))
                {
                    source.CopyTo(target);
                }
            }

            return assetDirectory;
        }

        private static void TrySetVariable(Runspace runspace, string name, object value)
        {
            try
            {
                runspace.SessionStateProxy.SetVariable(name, value);
            }
            catch
            {
                // Automatic PowerShell variables can be read-only on some hosts.
            }
        }

        private static void ShowPowerShellErrors(IList<ErrorRecord> errors)
        {
            if (errors == null || errors.Count == 0)
            {
                return;
            }

            StringBuilder message = new StringBuilder();
            int maximum = Math.Min(errors.Count, 5);
            for (int index = 0; index < maximum; index++)
            {
                if (index > 0)
                {
                    message.AppendLine();
                    message.AppendLine();
                }
                message.Append(errors[index].ToString());
            }

            MessageBox.Show(
                message.ToString(),
                AppName + " - Errori PowerShell",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
