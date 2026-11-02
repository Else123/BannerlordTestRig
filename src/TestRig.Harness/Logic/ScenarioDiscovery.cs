using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace TestRig.Harness.Logic
{
    /// <summary>Result of <see cref="ScenarioDiscovery.Discover"/>: the scenarios found and what had to be skipped.</summary>
    public sealed class ScenarioDiscoveryResult
    {
        internal ScenarioDiscoveryResult(IReadOnlyList<IScenario> scenarios, IReadOnlyList<string> notes)
        {
            Scenarios = scenarios;
            Notes = notes;
        }

        /// <summary>The instantiated scenarios in discovery order.</summary>
        public IReadOnlyList<IScenario> Scenarios { get; }

        /// <summary>
        /// Findings that never fail the run by themselves: assemblies whose types could only be read
        /// partially or not at all, and scenario types that were skipped (not inspectable, constructor
        /// or Id threw, empty Id).
        /// </summary>
        public IReadOnlyList<string> Notes { get; }

        /// <summary>
        /// <paramref name="error"/> followed by all notes. A skipped type has no known Id, so when a
        /// requested id cannot be resolved the notes are the only hint at the cause.
        /// </summary>
        public string WithNotes(string error)
        {
            return Notes.Count == 0 ? error : error + " (discovery notes: " + string.Join("; ", Notes) + ")";
        }
    }

    /// <summary>
    /// Finds the scenarios of the loaded plugin modules by reflection: every public, concrete,
    /// non-generic type implementing <see cref="IScenario"/> with a public parameterless constructor
    /// is instantiated once. Uses no engine API and references no mod assembly.
    /// </summary>
    public static class ScenarioDiscovery
    {
        /// <summary>
        /// Scans <paramref name="assemblies"/> (dynamic ones are skipped). An assembly whose types
        /// load only partially contributes the types that did load; one whose types cannot be read
        /// at all is skipped. Both cases are reported in Notes, not as an error.
        /// </summary>
        public static ScenarioDiscoveryResult Discover(IEnumerable<Assembly> assemblies)
        {
            if (assemblies == null)
            {
                throw new ArgumentNullException(nameof(assemblies));
            }

            var notes = new List<string>();
            var types = new List<Type>();
            foreach (Assembly assembly in assemblies)
            {
                if (assembly == null || assembly.IsDynamic)
                {
                    continue;
                }

                types.AddRange(LoadableTypes(assembly, notes));
            }

            return FromTypes(types, notes);
        }

        /// <summary>Instantiates the scenario types among <paramref name="types"/>; a failing type is skipped and noted.</summary>
        internal static ScenarioDiscoveryResult FromTypes(IEnumerable<Type> types, List<string> notes)
        {
            var scenarios = new List<IScenario>();
            foreach (Type type in types)
            {
                bool isScenario;
                try
                {
                    isScenario = IsScenarioType(type);
                }
                catch (Exception e)
                {
                    // E.g. a TypeLoadException because a base type or interface lives in a missing assembly.
                    notes.Add("type " + TypeName(type) + " could not be inspected, skipped: "
                        + e.GetType().Name + ": " + e.Message);
                    continue;
                }

                if (!isScenario)
                {
                    continue;
                }

                IScenario scenario;
                string error = TryCreate(type, out scenario);
                if (error != null)
                {
                    notes.Add(error);
                    continue;
                }

                scenarios.Add(scenario);
            }

            return new ScenarioDiscoveryResult(scenarios.AsReadOnly(), notes.AsReadOnly());
        }

        private static IEnumerable<Type> LoadableTypes(Assembly assembly, List<string> notes)
        {
            try
            {
                return assembly.GetTypes();
            }
            catch (ReflectionTypeLoadException e)
            {
                // Types that reference a missing assembly come back null; the rest is usable.
                Type[] loaded = (e.Types ?? new Type[0]).Where(t => t != null).ToArray();
                Exception first = e.LoaderExceptions == null ? null : e.LoaderExceptions.FirstOrDefault(x => x != null);
                notes.Add("assembly " + AssemblyName(assembly) + ": " + loaded.Length + " of "
                    + (e.Types == null ? 0 : e.Types.Length) + " types loadable"
                    + (first == null ? string.Empty : " (first loader error: " + first.Message + ")"));
                return loaded;
            }
            catch (Exception e)
            {
                notes.Add("assembly " + AssemblyName(assembly) + ": types not readable, skipped (" + e.Message + ")");
                return new Type[0];
            }
        }

        private static bool IsScenarioType(Type type)
        {
            return type.IsClass
                && type.IsVisible
                && !type.IsAbstract
                && !type.ContainsGenericParameters
                && typeof(IScenario).IsAssignableFrom(type)
                && type.GetConstructor(Type.EmptyTypes) != null;
        }

        // Returns null on success; otherwise a note naming the type (the type is then skipped).
        private static string TryCreate(Type type, out IScenario scenario)
        {
            scenario = null;
            IScenario created;
            try
            {
                created = (IScenario)Activator.CreateInstance(type);
            }
            catch (Exception e)
            {
                Exception cause = e is TargetInvocationException && e.InnerException != null ? e.InnerException : e;
                return "scenario type " + type.FullName + " skipped, could not be created: "
                    + cause.GetType().Name + ": " + cause.Message;
            }

            string id;
            try
            {
                id = created.Id;
            }
            catch (Exception e)
            {
                return "scenario type " + type.FullName + " skipped, reading Id threw " + e.GetType().Name + ": " + e.Message;
            }

            if (string.IsNullOrEmpty(id))
            {
                return "scenario type " + type.FullName + " skipped, it has an empty Id";
            }

            scenario = created;
            return null;
        }

        private static string TypeName(Type type)
        {
            try
            {
                return type.FullName ?? type.Name;
            }
            catch (Exception)
            {
                return "<unreadable>";
            }
        }

        private static string AssemblyName(Assembly assembly)
        {
            try
            {
                return assembly.GetName().Name;
            }
            catch (Exception)
            {
                return assembly.ToString();
            }
        }
    }
}
