// Jolly-Seber model using the superpopulation parameterization

functions {
  // These functions are derived from Section 12.3 of
  // Stan Modeling Language User's Guide and Reference Manual

  /**
   * Return a integer value of first capture occasion
   *
   * @param y_i Integer array of capture history
   *
   * @return Integer value of first capture occasion
   */
  int first_capture(int[] y_i) {
    for (k in 1:size(y_i))
      if (y_i[k])
        return k;
    return 0;
  }

  /**
   * Return a integer value of last capture occasion
   *
   * @param y_i Integer array of capture history
   *
   * @return Integer value of last capture occasion
   */
  int last_capture(int[] y_i) {
    for (k_rev in 0:(size(y_i) - 1)) {
      int k;
      k <- size(y_i) - k_rev;
      if (y_i[k])
        return k;
    }
    return 0;
  }

  /**
   * Return a matrix of uncaptured probability
   *
   * @param nind        Number of individuals
   * @param n_occasions Number of capture occasions
   * @param p           Detection probability for each individual
   *                    and capture occasion
   * @param phi         Survival probability for each individual
   *                    and capture occasion
   *
   * @return Uncaptured probability matrix
   */
  matrix prob_uncaptured(int nind, int n_occasions,
                         matrix p, matrix phi) {
    matrix[nind, n_occasions] chi;

    for (i in 1:nind) {
      chi[i, n_occasions] <- 1.0;
      for (t in 1:(n_occasions - 1)) {
        int t_curr;
        int t_next;

        t_curr <- n_occasions - t;
        t_next <- t_curr + 1;
        chi[i, t_curr] <- (1.0 - phi[i, t_curr])
          + phi[i, t_curr] * (1.0 - p[i, t_next]) * chi[i, t_next];
      }
    }
    return chi;
  }
}

data {
  int<lower=0> M;                              // Augmented sample size
  int<lower=0> n_occasions;                    // Number of capture occasions
  int<lower=0,upper=1> y[M, n_occasions];      // Augmented capture-history
}

transformed data {
  int<lower=0,upper=n_occasions> first[M];
  int<lower=0,upper=n_occasions> last[M];

  for (i in 1:M)
    first[i] <- first_capture(y[i]);
  for (i in 1:M)
    last[i] <- last_capture(y[i]);
}

parameters {
  real<lower=0,upper=1> mean_phi;             // Mean survival
  real<lower=0,upper=1> mean_p;               // Mean capture
  real<lower=0,upper=1> psi;                  // Inclusion probability
  vector<lower=0>[n_occasions] beta;
}

transformed parameters {
  matrix<lower=0,upper=1>[M, n_occasions-1] phi;
  matrix<lower=0,upper=1>[M, n_occasions] p;
  simplex[n_occasions] b;                     // Entry probability
  vector<lower=0,upper=1>[n_occasions] nu;
  matrix<lower=0,upper=1>[M, n_occasions] chi;

  // Constraints
  for (i in 1:M) {
    for (t in 1:(n_occasions - 1))
      phi[i, t] <- mean_phi;
    for (t in 1:n_occasions)
      p[i, t] <- mean_p;
  } //i

  // Dirichlet prior for entry probabilities
  // beta ~ gamma(1, 1);  // => model block
  b <- beta / sum(beta);

  // Convert entry probs to conditional entry probs
  nu[1] <- b[1];
  for (t in 2:(n_occasions - 1))
    nu[t] <- b[t] / (1.0 - sum(b[1:(t - 1)]));
  nu[n_occasions] <- 1.0;

  // Uncaptured probability
  chi <- prob_uncaptured(M, n_occasions, p, phi);
}

model {
  vector[n_occasions] qnu;

  qnu <- 1.0 - nu;

  // Priors
  mean_phi ~ uniform(0, 1);
  mean_p ~ uniform(0, 1);
  psi ~ uniform(0, 1);
  beta ~ gamma(1, 1);

  // Likelihood
  for (i in 1:M) {
    vector[n_occasions] qp;

    qp <- 1.0 - p[i]';

    if (first[i]) { // Observed
      // Included
      1 ~ bernoulli(psi);

      // Until first capture
      if (first[i] == 1) {
        1 ~ bernoulli(nu[1] * p[i, 1]);
      } else {  // first[i] >= 2
        vector[first[i]] lp;

        // Entered at 1st occasion
        lp[1] <- bernoulli_log(1, nu[1])
          + bernoulli_log(1, prod(qp[1:(first[i] - 1)]))
          + bernoulli_log(1, prod(phi[i, 1:(first[i] - 1)]))
          + bernoulli_log(1, p[i, first[i]]);
        // Entered at t-th occasion (1 < t < first[i])
        for (t in 2:(first[i] - 1))
          lp[t] <- bernoulli_log(1, prod(qnu[1:(t - 1)]))
            + bernoulli_log(1, nu[t])
            + bernoulli_log(1, prod(qp[t:(first[i] - 1)]))
            + bernoulli_log(1, prod(phi[i, t:(first[i] - 1)]))
            + bernoulli_log(1, p[i, first[i]]);
        lp[first[i]] <- bernoulli_log(1, prod(qnu[1:(first[i] - 1)]))
          + bernoulli_log(1, nu[first[i]])
          + bernoulli_log(1, p[i, first[i]]);
        increment_log_prob(log_sum_exp(lp));
      }
      // Until last capture
      for (t in (first[i] + 1):last[i]) {
        1 ~ bernoulli(phi[i, t - 1]);   // Survived
        y[i, t] ~ bernoulli(p[i, t]);   // Capture/Non-capture
      }
      // Subsequent occasions
      1 ~ bernoulli(chi[i, last[i]]);
    } else {          // Never observed
      vector[n_occasions+1] lp;

      // Entered at 1st occasion, but never captured
      lp[1] <- bernoulli_log(1, psi)
        + bernoulli_log(1, nu[1])
        + bernoulli_log(0, p[i, 1])
        + bernoulli_log(1, chi[i, 1]);
      // Entered at t-th occation (t > 1), but never captured
      for (t in 2:n_occasions)
        lp[t] <- bernoulli_log(1, psi)
          + bernoulli_log(1, prod(qnu[1:(t - 1)]))
          + bernoulli_log(1, nu[t])
          + bernoulli_log(0, p[i, t])
          + bernoulli_log(1, chi[i, t]);
      // Never captured
      lp[n_occasions + 1] <- bernoulli_log(0, psi);
      increment_log_prob(log_sum_exp(lp));
    }
  }
}

generated quantities {
  int<lower=0> Nsuper;                    // Superpopulation size
  int<lower=0> N[n_occasions];            // Actual population size
  int<lower=0> B[n_occasions];            // Number of entries
  int<lower=0,upper=1> w[M];              // Latent inclusion
  int<lower=0,upper=1> z[M, n_occasions]; // Latent state
  int<lower=0,upper=1> u[M, n_occasions]; // Deflated latent state

  // Generate w[] and z[]
  for (i in 1:M) {
    if (bernoulli_rng(psi)) {      // Included
      w[i] <- 1;
      z[i, 1] <- bernoulli_rng(nu[1]);
      for (t in 2:n_occasions) {
        z[i, t] <- bernoulli_rng(z[i, t - 1] * phi[i, t - 1]
                                 + (1 - z[i, t - 1]) * nu[t]);
      }
    } else {
      w[i] <- 0;
      for (t in 1:n_occasions)     // Not included
        z[i, t] <- 0;
    }
  }

  // Calculate derived population parameters
  {
    int recruit[M, n_occasions];
    int Nind[M];
    int Nalive[M];

    for (i in 1:M) {
      for (t in 1:n_occasions) {
        u[i, t] <- z[i, t] * w[i];
      }
    }
    for (i in 1:M) {
      recruit[i, 1] <- u[i, 1];
      for (t in 2:n_occasions)
        recruit[i,t] <- (1 - u[i, t - 1]) * u[i, t];
    } //i
    for (t in 1:n_occasions) {
      N[t] <- sum(u[1:M, t]);
      B[t] <- sum(recruit[1:M, t]);
    } //t
    for (i in 1:M) {
      Nind[i] <- sum(u[i]);
      Nalive[i] <- 1 - (Nind[i] == 0);
    } //i
    Nsuper <- sum(Nalive);
  }
}
