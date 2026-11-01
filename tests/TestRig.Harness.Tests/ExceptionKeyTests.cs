using System;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class ExceptionKeyTests
    {
        [Fact]
        public void Site_IsDeclaringTypeDotMethod()
        {
            Assert.Equal("Game.Inventory.Find", ExceptionKey.Site("Game.Inventory", "Find"));
        }

        [Fact]
        public void Site_WithoutDeclaringType_UsesAPlaceholderType()
        {
            Assert.Equal("?.Find", ExceptionKey.Site(null, "Find"));
        }

        [Fact]
        public void Site_WithoutMethod_IsUnknown()
        {
            Assert.Equal("?", ExceptionKey.Site("Game.Inventory", null));
            Assert.Equal("?", ExceptionKey.Site(null, null));
        }

        [Fact]
        public void Full_HasTypeMessageAndSite()
        {
            Assert.Equal(
                "System.InvalidOperationException: not found: item_7 @ Game.Inventory.Find",
                ExceptionKey.Full("System.InvalidOperationException", "not found: item_7", "Game.Inventory.Find"));
        }

        [Fact]
        public void Full_PutsAMultiLineMessageOnOneLine()
        {
            Assert.Equal(
                "System.Exception: a  b c @ ?",
                ExceptionKey.Full("System.Exception", "a\r\nb\nc", "?"));
        }

        [Fact]
        public void Full_TruncatesTheMessageTo200Characters()
        {
            string message = new string('x', 250);

            Assert.Equal(
                "System.Exception: " + new string('x', 200) + " @ ?",
                ExceptionKey.Full("System.Exception", message, "?"));
        }

        [Fact]
        public void Full_NullMessage_IsEmpty()
        {
            Assert.Equal("System.Exception:  @ ?", ExceptionKey.Full("System.Exception", null, "?"));
        }

        [Fact]
        public void Own_HasTypeAndSiteWithoutMessage()
        {
            Assert.Equal(
                "System.InvalidOperationException @ Game.Inventory.Find",
                ExceptionKey.Own("System.InvalidOperationException", "Game.Inventory.Find"));
        }

        [Fact]
        public void Own_ForAnExceptionWithVariableMessages_UsesOneWalkOnly()
        {
            var cache = new OwnClassificationCache(maxWalks: 10);
            int walks = 0;

            for (int i = 0; i < 1000; i++)
            {
                string fullKey = ExceptionKey.Full("System.InvalidOperationException", "not found: item_" + i, "Game.Inventory.Find");
                Assert.Contains("item_" + i, fullKey);

                string ownKey = ExceptionKey.Own("System.InvalidOperationException", "Game.Inventory.Find");
                bool own;
                if (cache.Lookup(ownKey, out own) == OwnLookup.Walk)
                {
                    walks++;
                    cache.Store(ownKey, true);
                }
            }

            Assert.Equal(1, walks);
            Assert.Equal(1, cache.Walks);
        }

        [Fact]
        public void Own_DifferentTypesOrSites_AreDifferentKeys()
        {
            string key = ExceptionKey.Own("System.Exception", "A.M");

            Assert.NotEqual(key, ExceptionKey.Own("System.ArgumentException", "A.M"));
            Assert.NotEqual(key, ExceptionKey.Own("System.Exception", "A.N"));
            Assert.NotEqual(key, ExceptionKey.Own("System.Exception", "B.M"));
        }
    }
}
