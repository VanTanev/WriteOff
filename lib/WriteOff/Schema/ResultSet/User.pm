package WriteOff::Schema::ResultSet::User;

use strict;
use base 'WriteOff::Schema::ResultSet';

sub with_prompt_skill {
	my $self = shift;
	
	my $inner = $self->result_source->schema->resultset('Prompt')->search(
		{ 'prompts.user_id' => { '=' => { -ident => 'me.id' } } },
		{
			select => [{ avg => 'prompts.rating' }],
			alias => 'prompts',
		}
	);
	
	return $self->search_rs(undef, {
		'+select' => [{ '' => $inner->as_query, -as => 'prompt_skill' }],
		'+as' => [ 'prompt_skill' ],
	});
}

sub resolve {
	my ($self, $user) = @_;
	return 0 unless $user;
	
	return $user->get_object if eval
		{ $user->isa('Catalyst::Authentication::Store::DBIx::Class::User') };
		
	return $user if eval { $user->isa('WriteOff::Model::DB::User') };
	return $self->find($user) || 0;
}

sub verified {
	return shift->search_rs({ verified => 1 });
}

sub mailing_list {	
	return shift->search_rs({ 
		mailme   => 1, 
		verified => 1,
	});
}

sub clean_unverified {
	my $self = shift;
	
	$self->search({ verified => 0 })
		->created_before( DateTime->now->subtract( days => 1 ) )
		->delete_all;
}

1;