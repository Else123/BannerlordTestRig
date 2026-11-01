using System;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class ExceptionLogBudgetTests
    {
        [Fact]
        public void FirstOccurrenceIsFull_RepeatsAreShortUpToTheAllowance_ThenDropped()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(maxDistinctFull: 10, repeatsPerKey: 2, maxLines: 100);
            int occurrence;

            Assert.Equal(ExceptionLogDecision.Full, budget.Next("A", out occurrence));
            Assert.Equal(1, occurrence);
            Assert.Equal(ExceptionLogDecision.Short, budget.Next("A", out occurrence));
            Assert.Equal(2, occurrence);
            Assert.Equal(ExceptionLogDecision.Short, budget.Next("A", out occurrence));
            Assert.Equal(3, occurrence);
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("A", out occurrence));
            Assert.Equal(4, occurrence);
            Assert.Equal(4, budget.Observed);
        }

        [Fact]
        public void KeysAreCountedIndependently()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(10, 0, 100);
            int occurrence;

            Assert.Equal(ExceptionLogDecision.Full, budget.Next("A", out occurrence));
            Assert.Equal(ExceptionLogDecision.Full, budget.Next("B", out occurrence));
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("A", out occurrence));
            Assert.Equal(2, occurrence);
        }

        [Fact]
        public void DistinctKeysBeyondTheFullCapAreDropped()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(maxDistinctFull: 1, repeatsPerKey: 5, maxLines: 100);
            int occurrence;

            Assert.Equal(ExceptionLogDecision.Full, budget.Next("A", out occurrence));
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("B", out occurrence));
            // A key already logged in full keeps its repeat allowance.
            Assert.Equal(ExceptionLogDecision.Short, budget.Next("A", out occurrence));
        }

        [Fact]
        public void LineCapStopsEverything()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(maxDistinctFull: 10, repeatsPerKey: 10, maxLines: 2);
            int occurrence;

            Assert.Equal(ExceptionLogDecision.Full, budget.Next("A", out occurrence));
            Assert.Equal(ExceptionLogDecision.Short, budget.Next("A", out occurrence));
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("B", out occurrence));
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("A", out occurrence));
            Assert.Equal(4, budget.Observed);
        }

        [Fact]
        public void StartWindowForgetsKeysAndRefillsTheBudget()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(maxDistinctFull: 1, repeatsPerKey: 0, maxLines: 1);
            int occurrence;
            budget.Next("A", out occurrence);
            Assert.Equal(ExceptionLogDecision.Drop, budget.Next("B", out occurrence));

            budget.StartWindow();

            Assert.Equal(0, budget.Observed);
            Assert.Equal(ExceptionLogDecision.Full, budget.Next("A", out occurrence));
            Assert.Equal(1, occurrence);
        }

        [Fact]
        public void NullKeyIsTreatedAsEmpty()
        {
            ExceptionLogBudget budget = new ExceptionLogBudget(10, 1, 10);
            int occurrence;

            Assert.Equal(ExceptionLogDecision.Full, budget.Next(null, out occurrence));
            Assert.Equal(ExceptionLogDecision.Short, budget.Next(string.Empty, out occurrence));
            Assert.Equal(2, occurrence);
        }

        [Fact]
        public void NegativeLimitsAreRejected()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => new ExceptionLogBudget(-1, 0, 0));
            Assert.Throws<ArgumentOutOfRangeException>(() => new ExceptionLogBudget(0, -1, 0));
            Assert.Throws<ArgumentOutOfRangeException>(() => new ExceptionLogBudget(0, 0, -1));
        }
    }
}
