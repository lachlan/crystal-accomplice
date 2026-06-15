require "./spec_helper"

describe Accomplice::Windows::Service do
  it "raises when shutdown_timeout is set to zero" do
    expect_raises(ArgumentError, /shutdown_timeout must be greater than zero.+/) do
      Accomplice::Windows::Service.shutdown_timeout = 0.seconds
    end
  end

  it "raises when shutdown_timeout is set to negative time span" do
    expect_raises(ArgumentError, /shutdown_timeout must be greater than zero.+/) do
      Accomplice::Windows::Service.shutdown_timeout = -1.second
    end
  end

  it "shutdown_timeout can be set to positive time span" do
    timeout = 1.second
    Accomplice::Windows::Service.shutdown_timeout = timeout
    Accomplice::Windows::Service.shutdown_timeout.should eq(timeout)
  end
end
