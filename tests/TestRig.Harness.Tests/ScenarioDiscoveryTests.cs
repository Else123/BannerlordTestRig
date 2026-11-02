using System;
using System.Collections.Generic;
using System.Reflection;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class ScenarioDiscoveryTests
    {
        // ---------------------------------------------------------------- sample types

        public sealed class GoodScenario : IScenario
        {
            public string Id
            {
                get { return "good"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public abstract class AbstractScenario : IScenario
        {
            public string Id
            {
                get { return "abstract"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public sealed class NoDefaultCtorScenario : IScenario
        {
            public NoDefaultCtorScenario(int unused)
            {
            }

            public string Id
            {
                get { return "no-default-ctor"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public sealed class GenericScenario<T> : IScenario
        {
            public string Id
            {
                get { return "generic"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        private sealed class PrivateScenario : IScenario
        {
            public string Id
            {
                get { return "private"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public sealed class ThrowingCtorScenario : IScenario
        {
            public ThrowingCtorScenario()
            {
                throw new InvalidOperationException("boom");
            }

            public string Id
            {
                get { return "throwing-ctor"; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public sealed class ThrowingIdScenario : IScenario
        {
            public string Id
            {
                get { throw new InvalidOperationException("no id"); }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        public sealed class EmptyIdScenario : IScenario
        {
            public string Id
            {
                get { return string.Empty; }
            }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                yield break;
            }
        }

        private static ScenarioDiscoveryResult FromTypes(params Type[] types)
        {
            return ScenarioDiscovery.FromTypes(types, new List<string>());
        }

        // ---------------------------------------------------------------- tests

        [Fact]
        public void FromTypes_InstantiatesOnlyPublicConcreteScenariosWithParameterlessCtor()
        {
            ScenarioDiscoveryResult result = FromTypes(
                typeof(GoodScenario),
                typeof(AbstractScenario),
                typeof(NoDefaultCtorScenario),
                typeof(GenericScenario<>),
                typeof(PrivateScenario),
                typeof(IScenario),
                typeof(string));

            IScenario only = Assert.Single(result.Scenarios);
            Assert.IsType<GoodScenario>(only);
        }

        [Fact]
        public void FromTypes_ThrowingCtor_IsSkippedAndNoted_OtherScenariosSurvive()
        {
            ScenarioDiscoveryResult result = FromTypes(typeof(ThrowingCtorScenario), typeof(GoodScenario));

            Assert.IsType<GoodScenario>(Assert.Single(result.Scenarios));
            string note = Assert.Single(result.Notes);
            Assert.Contains(typeof(ThrowingCtorScenario).FullName, note);
            Assert.Contains("InvalidOperationException: boom", note);
        }

        [Fact]
        public void FromTypes_ThrowingId_IsSkippedAndNoted()
        {
            ScenarioDiscoveryResult result = FromTypes(typeof(ThrowingIdScenario), typeof(GoodScenario));

            Assert.IsType<GoodScenario>(Assert.Single(result.Scenarios));
            string note = Assert.Single(result.Notes);
            Assert.Contains(typeof(ThrowingIdScenario).FullName, note);
            Assert.Contains("no id", note);
        }

        [Fact]
        public void FromTypes_EmptyId_IsSkippedAndNoted()
        {
            ScenarioDiscoveryResult result = FromTypes(typeof(EmptyIdScenario));

            Assert.Empty(result.Scenarios);
            Assert.Contains(typeof(EmptyIdScenario).FullName, Assert.Single(result.Notes));
        }

        [Fact]
        public void FromTypes_KeepsNotesPassedIn()
        {
            var notes = new List<string> { "earlier note" };

            ScenarioDiscoveryResult result = ScenarioDiscovery.FromTypes(new[] { typeof(ThrowingCtorScenario) }, notes);

            Assert.Equal(2, result.Notes.Count);
            Assert.Equal("earlier note", result.Notes[0]);
        }

        // A type whose reflection properties throw like a type with a missing dependency.
        private sealed class UnloadableType : TypeDelegator
        {
            public UnloadableType()
                : base(typeof(GoodScenario))
            {
            }

            protected override TypeAttributes GetAttributeFlagsImpl()
            {
                throw new TypeLoadException("dependency missing");
            }
        }

        [Fact]
        public void FromTypes_TypeThatCannotBeInspected_IsSkippedAndNoted()
        {
            ScenarioDiscoveryResult result = FromTypes(new UnloadableType(), typeof(GoodScenario));

            Assert.IsType<GoodScenario>(Assert.Single(result.Scenarios));
            string note = Assert.Single(result.Notes);
            Assert.Contains("TypeLoadException: dependency missing", note);
        }

        [Fact]
        public void WithNotes_AppendsAllNotesToTheError()
        {
            ScenarioDiscoveryResult result = FromTypes(typeof(ThrowingCtorScenario), typeof(EmptyIdScenario));

            string text = result.WithNotes("unknown scenario id 'x'");

            Assert.StartsWith("unknown scenario id 'x'", text);
            Assert.Contains(typeof(ThrowingCtorScenario).FullName, text);
            Assert.Contains(typeof(EmptyIdScenario).FullName, text);
        }

        [Fact]
        public void WithNotes_WithoutNotes_ReturnsTheErrorUnchanged()
        {
            Assert.Equal("unknown scenario id 'x'", FromTypes(typeof(GoodScenario)).WithNotes("unknown scenario id 'x'"));
        }

        // An assembly whose GetTypes throws, like one with a missing reference.
        private sealed class FakeAssembly : Assembly
        {
            private readonly Func<Type[]> _getTypes;

            public FakeAssembly(Func<Type[]> getTypes)
            {
                _getTypes = getTypes;
            }

            public override Type[] GetTypes()
            {
                return _getTypes();
            }

            public override AssemblyName GetName()
            {
                return new AssemblyName("FakeAssembly");
            }
        }

        [Fact]
        public void Discover_PartiallyLoadableAssembly_UsesLoadedTypesAndNotesTheRest()
        {
            var assembly = new FakeAssembly(() =>
            {
                throw new ReflectionTypeLoadException(
                    new[] { typeof(GoodScenario), null },
                    new Exception[] { new InvalidOperationException("missing dependency X") });
            });

            ScenarioDiscoveryResult result = ScenarioDiscovery.Discover(new Assembly[] { assembly });

            Assert.IsType<GoodScenario>(Assert.Single(result.Scenarios));
            string note = Assert.Single(result.Notes);
            Assert.Contains("FakeAssembly", note);
            Assert.Contains("1 of 2 types loadable", note);
            Assert.Contains("missing dependency X", note);
        }

        [Fact]
        public void Discover_ReflectionTypeLoadExceptionWithoutDetails_StillNotes()
        {
            var assembly = new FakeAssembly(() => throw new ReflectionTypeLoadException(null, null));

            ScenarioDiscoveryResult result = ScenarioDiscovery.Discover(new Assembly[] { assembly });

            Assert.Empty(result.Scenarios);
            Assert.Contains("0 of 0 types loadable", Assert.Single(result.Notes));
        }

        [Fact]
        public void Discover_UnreadableAssembly_IsSkippedAndNoted()
        {
            var assembly = new FakeAssembly(() => throw new NotSupportedException("no types"));

            ScenarioDiscoveryResult result = ScenarioDiscovery.Discover(new Assembly[] { assembly });

            Assert.Empty(result.Scenarios);
            string note = Assert.Single(result.Notes);
            Assert.Contains("types not readable", note);
            Assert.Contains("no types", note);
        }

        [Fact]
        public void Discover_SkipsNullAssembliesAndFindsTypesOfTheGivenAssemblies()
        {
            // The harness logic assembly is this test assembly; the core library has no scenarios.
            ScenarioDiscoveryResult result = ScenarioDiscovery.Discover(new[] { null, typeof(object).Assembly });

            Assert.Empty(result.Scenarios);
            Assert.Empty(result.Notes);
        }

        [Fact]
        public void Discover_NullAssemblies_Throws()
        {
            Assert.Throws<ArgumentNullException>(() => ScenarioDiscovery.Discover(null));
        }
    }
}
