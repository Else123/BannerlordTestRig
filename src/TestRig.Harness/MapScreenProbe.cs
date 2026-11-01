using System;
using System.Reflection;

namespace TestRig.Harness
{
    /// <summary>
    /// Read-only diagnostic view of the campaign map screen (SandBox.View.Map.MapScreen; NavalDLC
    /// derives NavalMapScreen from it). Reflection instead of a compile-time reference: the harness
    /// only reads two public properties for its log, and SandBox.View would drag in the whole
    /// ScreenSystem/Gauntlet reference set. MapScreen.IsReady is vanilla's own "scene ready to
    /// render" flag (set in HandleIfBlockerStatesDisabled once the scene view renders and
    /// the loading window can go).
    /// </summary>
    internal static class MapScreenProbe
    {
        private const string AssemblyName = "SandBox.View";
        private const string TypeName = "SandBox.View.Map.MapScreen";

        private static PropertyInfo _instance;
        private static PropertyInfo _isReady;

        /// <summary>"none", "NavalMapScreen ready=False", ... or "unknown"/"error ..." - never throws.</summary>
        public static string Describe()
        {
            try
            {
                if (!Resolve())
                {
                    return "unknown";
                }

                object screen = _instance.GetValue(null, null);
                if (screen == null)
                {
                    return "none";
                }

                return screen.GetType().Name + " ready=" + _isReady.GetValue(screen, null);
            }
            catch (Exception e)
            {
                return "error " + e.GetType().Name;
            }
        }

        // Retried until SandBox.View is loaded; it is, long before the first map tick.
        private static bool Resolve()
        {
            if (_instance != null && _isReady != null)
            {
                return true;
            }

            foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                if (assembly.GetName().Name != AssemblyName)
                {
                    continue;
                }

                Type type = assembly.GetType(TypeName, false);
                if (type == null)
                {
                    return false;
                }

                _instance = type.GetProperty("Instance", BindingFlags.Public | BindingFlags.Static);
                _isReady = type.GetProperty("IsReady", BindingFlags.Public | BindingFlags.Instance);
                return _instance != null && _isReady != null;
            }

            return false;
        }
    }
}
